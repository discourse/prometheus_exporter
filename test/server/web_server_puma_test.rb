# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "net/http"
require "openssl"
require "prometheus_exporter/client"
require "prometheus_exporter/server"
require "socket"
require "tmpdir"

class PrometheusExporterPumaWebServerTest < Minitest::Test
  include TlsTestChain

  class RecordingCollector
    attr_reader :payloads

    def initialize(metrics_text: "recorded_metric 1\n", error: nil, delay: nil)
      @metrics_text = metrics_text
      @error = error
      @delay = delay
      @payloads = []
      @mutex = Mutex.new
    end

    def process(payload)
      raise @error if @error

      @mutex.synchronize { @payloads << payload }
    end

    def prometheus_metrics_text
      sleep(@delay) if @delay
      @metrics_text
    end
  end

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ""
  end

  def test_puma_buffers_a_finite_body_and_delivers_one_opaque_record
    collector = RecordingCollector.new
    with_server(collector: collector) do |_server, port|
      socket = TCPSocket.new("127.0.0.1", port)
      socket.write(
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nopaque",
      )

      sleep(0.05)
      assert_empty(collector.payloads, "Puma must not call the app with a partial body")

      socket.write("\nbody")
      status, = read_response(socket)
      assert_equal(200, status)
      assert_equal(["opaque\nbody"], collector.payloads)
    ensure
      socket&.close
    end
  end

  def test_legacy_chunked_stream_is_processed_after_it_finishes
    collector = RecordingCollector.new
    with_server(collector: collector) do |_server, port|
      socket = TCPSocket.new("127.0.0.1", port)
      socket.write(
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nlegacy\r\n",
      )

      assert_nil(
        IO.select([socket], nil, nil, 0.1),
        "Puma buffers until the streaming request ends",
      )
      assert_empty(collector.payloads)

      socket.write("0\r\n\r\n")
      status, _headers, body = read_response(socket)
      assert_equal(200, status)
      assert_equal("OK", body)
      assert_equal(["legacy"], collector.payloads)
    ensure
      socket&.close
    end
  end

  # Each completed request body is passed to the collector as a single opaque
  # payload, whether it is one JSON object, several adjacent objects, or non-JSON.
  def test_each_completed_body_is_delivered_verbatim_as_one_payload
    collector = RecordingCollector.new
    bodies = [
      JSON.generate(name: "one"),
      JSON.generate(name: "a") + JSON.generate(name: "b"),
      "{]{}",
    ]

    with_server(collector: collector) do |server, port|
      bodies.each { |body| assert_equal("200", post(port, body).code) }

      assert_equal(bodies, collector.payloads)
      assert_match(/collector_metrics_total 3/, server.metrics)
      assert_match(/collector_sessions_total 3/, server.metrics)
    end
  end

  def test_send_metrics_requires_post
    collector = RecordingCollector.new
    with_server(collector: collector) do |_server, port|
      response = Net::HTTP.get_response("127.0.0.1", "/send-metrics", port)
      assert_equal("405", response.code)
      assert_equal("POST", response["Allow"])
      assert_empty(collector.payloads)
    end
  end

  def test_collector_errors_return_their_status_and_increment_bad_metrics
    error = Class.new(StandardError) { def status_code = 422 }.new("invalid opaque record")
    collector = RecordingCollector.new(error: error)
    with_server(collector: collector) do |server, port|
      response = post(port, "bad")
      assert_equal("422", response.code)
      assert_match(/Bad Metrics invalid opaque record/, response.body)
      metrics = server.metrics
      assert_match(/collector_metrics_total 1/, metrics)
      assert_match(/collector_sessions_total 1/, metrics)
      assert_match(/collector_bad_metrics_total 1/, metrics)
    end
  end

  def test_metrics_timeout_and_self_metrics_are_preserved
    collector = RecordingCollector.new(delay: 0.05)
    server =
      PrometheusExporter::Server::WebServer.new(
        port: free_port,
        bind: "127.0.0.1",
        timeout: 0.001,
        collector: collector,
      )

    output = server.metrics
    assert_match(/collector_working 0/, output)
    assert_match(/collector_metrics_total 0/, output)
    assert_match(/collector_sessions_total 0/, output)
    assert_match(/collector_bad_metrics_total 0/, output)
  ensure
    server&.stop
  end

  def test_start_is_idempotent_and_stop_joins_puma
    server =
      PrometheusExporter::Server::WebServer.new(
        port: free_port,
        bind: "127.0.0.1",
        collector: RecordingCollector.new,
      )
    runner = server.start
    assert_same(runner, server.start)
    assert_predicate(runner, :alive?)

    server.stop
    refute_predicate(runner, :alive?)
  ensure
    server&.stop
  end

  def test_verbose_logging_uses_the_requested_target
    log = StringIO.new
    with_server(
      collector: RecordingCollector.new,
      verbose: true,
      log_target: log,
    ) do |_server, port|
      assert_equal("PONG", Net::HTTP.get("127.0.0.1", "/ping", port))
      assert_match(%r{GET /ping}, log.string)
    end
  end

  def test_any_bind_accepts_ipv4_and_ipv6_when_the_host_supports_it
    collector = RecordingCollector.new
    with_server(collector: collector, bind: "ANY") do |_server, port|
      assert_equal("PONG", Net::HTTP.get("127.0.0.1", "/ping", port))

      if Socket.ip_address_list.any?(&:ipv6_loopback?)
        begin
          assert_equal("PONG", Net::HTTP.get("::1", "/ping", port))
        rescue Errno::EADDRNOTAVAIL, Errno::ECONNREFUSED
          skip "this host exposes IPv6 loopback but cannot bind it"
        end
      end
    end
  end

  def test_server_and_client_tls
    Dir.mktmpdir("prometheus-exporter-tls") do |directory|
      paths = write_tls_chain(directory)
      collector = RecordingCollector.new
      with_server(
        collector: collector,
        tls_cert_file: paths[:server_cert],
        tls_key_file: paths[:server_key],
      ) do |_server, port|
        client =
          PrometheusExporter::Client.new(
            host: "localhost",
            port: port,
            process_queue_once_and_stop: true,
            tls_ca_file: paths[:ca_cert],
            tls_cert_file: paths[:client_cert],
            tls_key_file: paths[:client_key],
          )
        client.send("tls opaque payload")
        assert_equal(["tls opaque payload"], collector.payloads)
      ensure
        client&.stop
      end
    end
  end

  def test_tls_hostname_mismatch_is_rejected
    Dir.mktmpdir("prometheus-exporter-tls") do |directory|
      paths = write_tls_chain(directory)
      collector = RecordingCollector.new
      with_server(
        collector: collector,
        tls_cert_file: paths[:server_cert],
        tls_key_file: paths[:server_key],
      ) do |_server, port|
        logs = StringIO.new
        client =
          PrometheusExporter::Client.new(
            host: "127.0.0.1",
            port: port,
            process_queue_once_and_stop: true,
            logger: Logger.new(logs),
            tls_ca_file: paths[:ca_cert],
            tls_cert_file: paths[:client_cert],
            tls_key_file: paths[:client_key],
          )
        client.send("must not arrive")

        assert_empty(collector.payloads)
        assert_match(/does not match the server certificate/, logs.string)
      ensure
        client&.stop
      end
    end
  end

  def test_partial_server_tls_configuration_fails_fast
    error =
      assert_raises(ArgumentError) do
        PrometheusExporter::Server::WebServer.new(
          port: 0,
          bind: "127.0.0.1",
          collector: RecordingCollector.new,
          tls_cert_file: "cert.pem",
        )
      end

    assert_match(/must be configured together/, error.message)
  end

  # max_record_size is wired through to Puma's http_content_length_limit, so an
  # oversize body is rejected with a 413 before the app is invoked. Puma owns the
  # enforcement across framings; we only confirm the limit is plumbed through.
  def test_oversized_body_is_rejected_with_413
    with_server(collector: RecordingCollector.new, max_record_size: 16) do |_server, port|
      socket = TCPSocket.new("127.0.0.1", port)
      socket.write(
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\n" \
          "Content-Length: 17\r\n\r\n0123456789abcdefg",
      )

      status, = read_response(socket)
      assert_equal(413, status)
    ensure
      socket&.close
    end
  end

  def test_localhost_binds_every_loopback_on_one_port_and_releases_it_on_stop
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.local_address.ip_port
    probe.close

    server =
      PrometheusExporter::Server::WebServer.new(port: port, collector: RecordingCollector.new)
    server.start

    assert_equal(port, server.port)
    assert_equal("PONG", Net::HTTP.get("127.0.0.1", "/ping", port))
    if Socket.ip_address_list.any?(&:ipv6_loopback?)
      assert_equal("PONG", Net::HTTP.get("::1", "/ping", port))
    end
    server.stop

    replacement = TCPServer.new("127.0.0.1", port)
    assert_equal(port, replacement.local_address.ip_port)
  ensure
    server&.stop
    replacement&.close
  end

  def test_stop_before_start_closes_owned_log_file
    skip "file-descriptor inspection requires /proc" unless Dir.exist?("/proc/self/fd")

    Dir.mktmpdir("prometheus-exporter-log") do |directory|
      path = File.join(directory, "server.log")
      server =
        PrometheusExporter::Server::WebServer.new(
          port: 0,
          bind: "127.0.0.1",
          collector: RecordingCollector.new,
          log_target: path,
        )
      assert_operator(open_descriptors_for(path), :>, 0)

      server.stop
      assert_equal(0, open_descriptors_for(path))
    end
  end

  def test_start_failure_cleans_listeners_and_allows_retry_until_terminal_stop
    blocker = TCPServer.new("127.0.0.1", 0)
    port = blocker.local_address.ip_port
    Dir.mktmpdir("prometheus-exporter-log") do |directory|
      path = File.join(directory, "server.log")
      server =
        PrometheusExporter::Server::WebServer.new(
          port: port,
          bind: "127.0.0.1",
          collector: RecordingCollector.new,
          log_target: path,
        )

      assert_raises(Errno::EADDRINUSE) { server.start }
      assert_operator(open_descriptors_for(path), :>, 0)

      blocker.close
      blocker = nil
      runner = server.start
      assert_predicate(runner, :alive?)
      assert_equal("PONG", Net::HTTP.get("127.0.0.1", "/ping", port))

      server.stop
      assert_equal(0, open_descriptors_for(path))
      error = assert_raises(RuntimeError) { server.start }
      assert_match(/has been stopped/, error.message)
    ensure
      server&.stop
    end

    replacement = TCPServer.new("127.0.0.1", port)
    assert_equal(port, replacement.local_address.ip_port)
  ensure
    blocker&.close
    replacement&.close
  end

  def test_quiet_server_honors_explicit_log_target
    logs = StringIO.new
    collector = RecordingCollector.new(error: StandardError.new("quiet failure"))
    with_server(collector: collector, verbose: false, log_target: logs) do |_server, port|
      response = post(port, "bad")
      assert_equal("500", response.code)
      assert_match(/quiet failure/, logs.string)
    end
  end

  def test_realm_rejects_header_control_characters
    error =
      assert_raises(ArgumentError) do
        PrometheusExporter::Server::WebServer.new(
          port: 0,
          collector: RecordingCollector.new,
          realm: "unsafe\r\nX-Injected: yes",
        )
      end

    assert_match(/control characters/, error.message)
  end

  def test_gzip_is_negotiated_by_accept_encoding_and_vary_is_always_set
    with_server(collector: RecordingCollector.new) do |_server, port|
      compressed = get_metrics(port, "gzip")
      assert_equal("gzip", compressed["Content-Encoding"])
      assert_equal("Accept-Encoding", compressed["Vary"])

      plain = get_metrics(port, "br")
      assert_nil(plain["Content-Encoding"])
      assert_equal("Accept-Encoding", plain["Vary"])
    end
  end

  private

  def with_server(collector:, bind: "127.0.0.1", **options)
    port = free_port
    server =
      PrometheusExporter::Server::WebServer.new(
        { port: port, bind: bind, collector: collector }.merge(options),
      )
    server.start
    yield server, port
  ensure
    server&.stop
  end

  def free_port
    socket = TCPServer.new("127.0.0.1", 0)
    socket.local_address.ip_port
  ensure
    socket&.close
  end

  def post(port, body)
    Net::HTTP.start("127.0.0.1", port) do |http|
      request = Net::HTTP::Post.new("/send-metrics")
      request.body = body
      http.request(request)
    end
  end

  def read_response(socket)
    status_line = socket.gets("\n")
    status = status_line.split(" ", 3)[1].to_i
    headers = {}
    while (line = socket.gets("\n")) != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(Integer(headers.fetch("content-length"), 10))
    [status, headers, body]
  end

  def get_metrics(port, accept_encoding)
    Net::HTTP.start("127.0.0.1", port) do |http|
      request = Net::HTTP::Get.new("/metrics")
      request["Accept-Encoding"] = accept_encoding
      http.request(request)
    end
  end

  def open_descriptors_for(path)
    Dir
      .glob("/proc/self/fd/*")
      .count do |descriptor|
        File.realpath(descriptor) == File.realpath(path)
      rescue Errno::ENOENT
        false
      end
  end
end
