# frozen_string_literal: true

require_relative "web_server_test_helper"
require "English"
require "openssl"

class BlockingCollector < DemoCollector
  attr_reader :started

  def initialize
    super
    @started = Queue.new
  end

  def process(_str)
    @started << true
    sleep 30
  end
end

class PrometheusExporterSocketListenerTest < WebServerTestCase
  def test_serves_clients_concurrently
    _server, port = start_server(header_timeout: 1)
    stalled = TCPSocket.new("127.0.0.1", port)
    stalled.write("GET /ping HTTP/1.1\r\nHost: stalled")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, _headers, body = raw_request(port, "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 200, status
    assert_equal "PONG", body
    assert_operator elapsed, :<, 0.5
  ensure
    stalled&.close
  end

  def test_stop_unblocks_accept_and_socket_workers
    server, port = start_server(header_timeout: 30)
    stalled = TCPSocket.new("127.0.0.1", port)
    stalled.write("GET /ping HTTP/1.1\r\n")
    sleep 0.02

    stopper = Thread.new { server.stop }
    assert stopper.join(1), "server.stop did not terminate its accept and worker threads"
    assert_equal "", stalled.read
    assert_raises(Errno::ECONNREFUSED, Errno::ECONNRESET) { TCPSocket.new("127.0.0.1", port) }
  ensure
    stalled&.close
  end

  def test_stop_remains_prompt_when_collector_code_is_blocked
    collector = BlockingCollector.new
    server, port = start_server(collector: collector, stop_timeout: 0.03)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write("POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}")
    queue_pop(collector.started)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    server.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.5
    assert_equal "", socket.read
  ensure
    socket&.close
  end

  def test_worker_cap_leaves_connections_in_the_kernel_backlog_until_capacity_returns
    server, port = start_server(max_connections: 3, header_timeout: 2, body_read_timeout: 2)
    stalled = 3.times.map { TCPSocket.new("127.0.0.1", port) }
    stalled.each { |socket| socket.write("GET /ping HTTP/1.1\r\nHost: stalled") }
    assert TestHelper.wait_for(1) { worker_count(server) == 3 }

    queued = TCPSocket.new("127.0.0.1", port)
    queued.write("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    refute IO.select([queued], nil, nil, 0.2), "queued connection was accepted or reset at capacity"
    assert_equal 3, worker_count(server)

    stalled.pop.close
    status, _headers, body = read_response(queued)
    assert_equal 200, status
    assert_equal "PONG", body
    assert_operator worker_count(server), :<=, 3
  ensure
    queued&.close
    stalled&.each { |socket| socket.close unless socket.closed? }
  end

  def test_accept_loop_continues_after_an_aborted_connection
    port = free_port
    server = PrometheusExporter::Server::WebServer.new(port: port, bind: "127.0.0.1")
    @servers << server
    socket_listener = listener(server)
    original_accept = socket_listener.method(:accept_socket)
    attempts = 0
    socket_listener.define_singleton_method(:accept_socket) do |listener|
      attempts += 1
      raise Errno::ECONNABORTED if attempts == 1

      original_accept.call(listener)
    end
    server.start

    status, _headers, body = raw_request(port, "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_equal 200, status
    assert_equal "PONG", body
    assert_operator attempts, :>=, 2
    assert_nil server.accept_error
  end

  def test_accept_loop_retries_temporary_file_descriptor_exhaustion
    port = free_port
    server = PrometheusExporter::Server::WebServer.new(port: port, bind: "127.0.0.1")
    @servers << server
    socket_listener = listener(server)
    original_accept = socket_listener.method(:accept_socket)
    attempts = 0
    socket_listener.define_singleton_method(:accept_socket) do |listener|
      attempts += 1
      raise Errno::EMFILE if attempts <= 2

      original_accept.call(listener)
    end
    server.start

    status, _headers, body = raw_request(port, "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_equal 200, status
    assert_equal "PONG", body
    assert_operator attempts, :>=, 3
    assert_nil server.accept_error
  end

  def test_fatal_accept_failure_is_observable_and_leaves_a_stoppable_server
    log = StringIO.new
    port = free_port
    server =
      PrometheusExporter::Server::WebServer.new(port: port, bind: "127.0.0.1", log_target: log)
    @servers << server
    socket_listener = listener(server)
    socket_listener.define_singleton_method(:accept_socket) { |_listener| raise Errno::EIO }
    server.start
    probe = TCPSocket.new("127.0.0.1", port)

    assert TestHelper.wait_for(1) { server.accept_error }
    assert_instance_of Errno::EIO, server.accept_error
    assert_match(/Failed to run prometheus collector web/, log.string)
    runner =
      socket_listener
        .instance_variable_get(:@state_mutex)
        .synchronize { socket_listener.instance_variable_get(:@runner) }
    assert_nil runner
    server.stop
  ensure
    probe&.close
  end

  def test_tls
    cert_file, key_file = tls_files
    _server, port = start_server(tls_cert_file: cert_file.path, tls_key_file: key_file.path)
    tcp_socket = TCPSocket.new("127.0.0.1", port)
    context = OpenSSL::SSL::SSLContext.new
    context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, context)
    socket.sync_close = true
    socket.connect
    socket.write("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")

    status, headers, body = read_response(socket)
    assert_equal 200, status
    assert_equal "PONG", body
    assert_fixed_response(headers, body)
  ensure
    socket&.close
    tcp_socket&.close
  end

  def test_tls_configuration_requires_certificate_and_key_together
    cert_file, key_file = tls_files

    error =
      assert_raises(ArgumentError) do
        PrometheusExporter::Server::WebServer.new(
          port: free_port,
          bind: "127.0.0.1",
          tls_cert_file: cert_file.path,
        )
      end
    assert_match(/supplied together/, error.message)

    assert_raises(ArgumentError) do
      PrometheusExporter::Server::WebServer.new(
        port: free_port,
        bind: "127.0.0.1",
        tls_key_file: key_file.path,
      )
    end
  end

  def test_tls_configuration_rejects_a_mismatched_private_key
    cert_file, = tls_files
    different_key = OpenSSL::PKey::RSA.new(2048)
    key_file = tempfile
    key_file.write(different_key.to_pem)
    key_file.flush

    error =
      assert_raises(ArgumentError) do
        PrometheusExporter::Server::WebServer.new(
          port: free_port,
          bind: "127.0.0.1",
          tls_cert_file: cert_file.path,
          tls_key_file: key_file.path,
        )
      end
    assert_match(/do not match/, error.message)
  end

  def test_plain_http_does_not_load_openssl_even_on_disconnect_rescue_paths
    script = <<~'RUBY'
      require "prometheus_exporter"
      require "prometheus_exporter/server"
      abort "OpenSSL loaded during require" if defined?(OpenSSL)

      server = PrometheusExporter::Server::WebServer.new(port: 0, bind: "127.0.0.1")
      listener = server.instance_variable_get(:@listener)
      port = listener.local_port
      server.start
      disconnected = TCPSocket.new("127.0.0.1", port)
      disconnected.write("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
      disconnected.close
      socket = TCPSocket.new("127.0.0.1", port)
      socket.write("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
      abort "plain HTTP request failed" unless socket.read.include?("200 OK")
      socket.close
      failing_socket = Object.new
      failing_socket.define_singleton_method(:closed?) { false }
      failing_socket.define_singleton_method(:write_nonblock) { |*| raise "write failure" }
      begin
        listener.send(:build_connection, failing_socket).send(:write_response, 200, "body", {})
      rescue RuntimeError => error
        raise unless error.message == "write failure"
      end
      abort "OpenSSL loaded by rescue handling" if defined?(OpenSSL)
      server.stop
      abort "OpenSSL loaded by plain HTTP" if defined?(OpenSSL)
    RUBY
    output = IO.popen([RbConfig.ruby, "-Ilib", "-e", script], err: %i[child out], &:read)

    assert_predicate $CHILD_STATUS, :success?, output
  end

  def test_bundled_tls_client_uploads_payload_larger_than_tls_record
    collector = DemoCollector.new
    cert_file, key_file = tls_files
    _server, port =
      start_server(collector: collector, tls_cert_file: cert_file.path, tls_key_file: key_file.path)
    client =
      PrometheusExporter::Client.new(
        host: "localhost",
        port: port,
        thread_sleep: 0.001,
        tls_ca_file: cert_file.path,
        tls_cert_file: cert_file.path,
        tls_key_file: key_file.path,
      )
    @clients << client
    padding = "x" * (20 * 1024)

    client.send_json "type" => "mem metric", "value" => 77, "padding" => padding

    payload = JSON.parse(queue_pop(collector.processed, timeout: 2))
    assert_equal 77, payload["value"]
    assert_equal padding, payload["padding"]
  end

  def test_ipv6
    skip "IPv6 loopback is unavailable" unless ipv6_available?

    port = free_port("::1")
    server = PrometheusExporter::Server::WebServer.new(port: port, bind: "::1")
    @servers << server
    server.start

    status, _headers, body =
      raw_request(port, "GET /ping HTTP/1.1\r\nHost: [::1]\r\n\r\n", host: "::1")
    assert_equal 200, status
    assert_equal "PONG", body
  end

  def test_bundled_client_uploads_over_ipv6
    skip "IPv6 loopback is unavailable" unless ipv6_available?

    collector = DemoCollector.new
    _server, port = start_server(bind: "::1", collector: collector)
    client = PrometheusExporter::Client.new(host: "::1", port: port, thread_sleep: 0.001)
    @clients << client

    client.send_json "type" => "mem metric", "value" => 99

    assert_equal 99, JSON.parse(queue_pop(collector.processed))["value"]
    assert_includes collector.prometheus_metrics_text, "memory 99"
  end

  def test_any_and_all_bind_ipv4_and_ipv6_as_available
    %w[ANY ALL].each do |bind|
      port = free_port
      server = PrometheusExporter::Server::WebServer.new(port: port, bind: bind)
      @servers << server
      server.start

      status, = raw_request(port, "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
      assert_equal 200, status

      if ipv6_available?
        status, = raw_request(port, "GET /ping HTTP/1.1\r\nHost: [::1]\r\n\r\n", host: "::1")
        assert_equal 200, status
      end
    end
  end

  private

  def listener(server)
    server.instance_variable_get(:@listener)
  end

  def worker_count(server)
    socket_listener = listener(server)
    socket_listener
      .instance_variable_get(:@state_mutex)
      .synchronize { socket_listener.instance_variable_get(:@workers).length }
  end

  def tls_files
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = OpenSSL::X509::Name.parse("/CN=localhost")
    certificate.issuer = certificate.subject
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))

    cert_file = tempfile
    cert_file.write(certificate.to_pem)
    cert_file.flush
    key_file = tempfile
    key_file.write(key.to_pem)
    key_file.flush
    [cert_file, key_file]
  end

  def ipv6_available?
    server = TCPServer.new("::1", 0)
    true
  rescue SocketError, SystemCallError
    false
  ensure
    server&.close
  end
end
