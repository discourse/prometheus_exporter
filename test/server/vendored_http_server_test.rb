# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/server"
require "fileutils"
require "logger"
require "net/http"
require "openssl"
require "open3"
require "rbconfig"
require "rubygems"
require "tmpdir"
require "zlib"

class VendoredHTTPServerTest < Minitest::Test
  class RecordingCollector
    def initialize
      @processed = Queue.new
      @values = []
      @mutex = Mutex.new
    end

    def process(value)
      @mutex.synchronize { @values << value }
      @processed << value
    end

    def next_value(timeout: 2)
      Timeout.timeout(timeout) { @processed.pop }
    end

    def values
      @mutex.synchronize { @values.dup }
    end

    def prometheus_metrics_text
      "recorded_metric #{@mutex.synchronize { @values.length }}\n"
    end
  end

  class BlockingCollector < RecordingCollector
    attr_reader :entered

    def initialize
      super
      @entered = Queue.new
      @release = Queue.new
    end

    def process(value)
      @entered << value
      @release.pop
      super
    end
  end

  class LargeResponseCollector < RecordingCollector
    attr_reader :rendered

    def initialize(bytes)
      super()
      @body = "x" * bytes
      @rendered = Queue.new
    end

    def prometheus_metrics_text
      @rendered << true
      @body
    end
  end

  class StatusErrorCollector < RecordingCollector
    def initialize(status)
      super()
      @status = status
    end

    def process(_value)
      error = StandardError.new("collector rejected metrics")
      error.define_singleton_method(:status_code) { @status }
      error.instance_variable_set(:@status, @status)
      raise error
    end
  end

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ""
    @servers = []
    @http_servers = []
    @sockets = []
  end

  def teardown
    @sockets.each { |socket| socket.close unless socket.closed? }
    @servers.reverse_each(&:stop)
    @http_servers.reverse_each(&:shutdown)
  end

  def test_processes_delayed_and_split_chunks_before_terminal_chunk
    collector = RecordingCollector.new
    port = free_port
    start_server(port: port, collector: collector)
    socket = connect(port)
    socket.write(
      "POST /send-metrics HTTP/1.1\r\n" \
        "Host: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n" \
        "Connection: close\r\n\r\n",
    )

    first = '{"value":1}'
    socket.write("#{first.bytesize.to_s(16)}\r\n#{first}\r\n")
    assert_equal(first, collector.next_value, "first chunk was not processed before termination")

    second = '{"value":2}'
    framing = "#{second.bytesize.to_s(16)}\r\n#{second}\r\n"
    framing.each_byte { |byte| socket.write(byte.chr) }
    assert_equal(second, collector.next_value, "chunk split across writes was not reconstructed")

    assert_equal([first, second], collector.values)
    socket.write("0\r\n\r\n")
    status, = read_response(socket)
    assert_equal(200, status)
  end

  def test_rejects_malformed_requests_without_killing_listener
    collector = RecordingCollector.new
    port = free_port
    start_server(port: port, collector: collector)

    requests = {
      400 => [
        "GET /ping HTTP/1.1\r\nBad Header\r\n\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n0\r\n\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: nope\r\n\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nxNOPE\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nBad Trailer\r\n\r\n",
      ],
      501 => [
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
      ],
    }

    requests.each do |expected_status, raw_requests|
      raw_requests.each do |request|
        socket = connect(port)
        socket.write(request)
        status, = read_response(socket)
        assert_equal(expected_status, status, request.inspect)
        socket.close

        assert_ping(port)
      end
    end
  end

  def test_enforces_request_line_and_total_header_limits
    port = free_port
    start_server(port: port, collector: RecordingCollector.new)

    socket = connect(port)
    socket.write("GET /#{"a" * 2_100} HTTP/1.1\r\n\r\n")
    status, = read_response(socket)
    assert_equal(414, status)
    socket.close

    socket = connect(port)
    headers = "X-Test: #{"a" * 100}\r\n" * 1_200
    socket.write("GET /ping HTTP/1.1\r\n#{headers}\r\n")
    status, = read_response(socket)
    assert_equal(413, status)

    assert_ping(port)
  end

  def test_basic_auth_uses_crypt_and_returns_challenge
    Dir.mktmpdir do |directory|
      auth_file = File.join(directory, "htpasswd")
      File.write(auth_file, "scraper:#{"secret".crypt("pe")}\n")
      port = free_port
      start_server(port: port, collector: RecordingCollector.new, auth: auth_file, realm: "Metrics")

      status, headers, body = raw_get(port, "/metrics")
      assert_equal(401, status)
      assert_equal("Basic realm=\"Metrics\"", headers["www-authenticate"])
      assert_equal("Unauthorized", body)

      wrong = ["scraper:wrong"].pack("m0")
      status, = raw_get(port, "/metrics", { "Authorization" => "Basic #{wrong}" })
      assert_equal(401, status)

      credentials = ["scraper:secret"].pack("m0")
      status, _, body = raw_get(port, "/metrics", { "Authorization" => "Basic #{credentials}" })
      assert_equal(200, status)
      assert_includes(body, "recorded_metric 0")
    end
  end

  def test_metrics_plain_gzip_ping_and_not_found
    port = free_port
    start_server(port: port, collector: RecordingCollector.new)

    status, headers, body = raw_get(port, "/metrics", { "Accept-Encoding" => "identity" })
    assert_equal(200, status)
    refute(headers.key?("content-encoding"))
    assert_includes(body, "recorded_metric 0")

    status, headers, compressed = raw_get(port, "/metrics", { "Accept-Encoding" => "gzip" })
    assert_equal(200, status)
    assert_equal("gzip", headers["content-encoding"])
    assert_includes(Zlib::GzipReader.new(StringIO.new(compressed)).read, "recorded_metric 0")

    status, headers, body = raw_get(port, "/metrics", { "Accept-Encoding" => "gzip;q=0, *;q=1" })
    assert_equal(200, status)
    refute(headers.key?("content-encoding"))
    assert_includes(body, "recorded_metric 0")

    status, headers, compressed = raw_get(port, "/metrics", { "Accept-Encoding" => "*;q=0.5" })
    assert_equal(200, status)
    assert_equal("gzip", headers["content-encoding"])
    assert_includes(Zlib::GzipReader.new(StringIO.new(compressed)).read, "recorded_metric 0")

    assert_ping(port)
    status, _, body = raw_get(port, "/missing")
    assert_equal(404, status)
    assert_equal(
      "Not Found! The Prometheus Ruby Exporter only listens on /ping, /metrics and /send-metrics",
      body,
    )
  end

  def test_http_1_0_and_1_1_keep_alive
    port = free_port
    start_server(port: port, collector: RecordingCollector.new)

    socket = connect(port)
    socket.write("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    status, headers, body = read_response(socket)
    assert_equal([200, "PONG"], [status, body])
    refute_equal("close", headers["connection"])
    socket.write("GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    assert_equal(200, read_response(socket).first)
    socket.close

    socket = connect(port)
    socket.write("GET /ping HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
    status, headers, = read_response(socket)
    assert_equal(200, status)
    assert_equal("Keep-Alive", headers["connection"])
    socket.write("GET /ping HTTP/1.0\r\nConnection: close\r\n\r\n")
    assert_equal(200, read_response(socket).first)
  end

  def test_validates_and_ignores_all_chunked_trailers
    collector = RecordingCollector.new
    port = free_port
    start_server(port: port, collector: collector)
    payload = "metric"
    request =
      "POST /send-metrics HTTP/1.1\r\n" \
        "Host: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n" \
        "Trailer: Content-Length, X-Trace\r\n" \
        "Connection: close\r\n\r\n" \
        "#{payload.bytesize.to_s(16)}\r\n#{payload}\r\n" \
        "0\r\nContent-Length: 999\r\nX-Trace: ignored\r\n\r\n"
    socket = connect(port)
    socket.write(request)

    assert_equal(payload, collector.next_value)
    assert_equal(200, read_response(socket).first)
    assert_ping(port)
  end

  def test_max_clients_bounds_concurrent_connections
    collector = RecordingCollector.new
    port = free_port
    start_server(port: port, collector: collector, max_clients: 1)

    first = connect(port)
    first.write(
      "POST /send-metrics HTTP/1.1\r\n" \
        "Host: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n" \
        "Connection: close\r\n\r\n" \
        "1\r\nx\r\n",
    )
    assert_equal("x", collector.next_value)

    second = connect(port)
    second.write("GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    refute(
      IO.select([second], nil, nil, 0.05),
      "second client ran while the only slot was occupied",
    )

    first.write("0\r\n\r\n")
    assert_equal(200, read_response(first).first)
    status, _, body = read_response(second)
    assert_equal([200, "PONG"], [status, body])
  end

  def test_request_read_timeout_returns_408_and_listener_survives
    port = free_port
    start_server(port: port, collector: RecordingCollector.new, request_timeout: 0.1)
    socket = connect(port)
    socket.write("GET /ping HTTP/1.1\r\nX-Partial:")

    assert_equal(408, read_response(socket).first)
    assert_ping(port)
  end

  def test_stop_interrupts_partial_request_and_allows_immediate_port_reuse
    port = free_port
    collector = RecordingCollector.new
    server = start_server(port: port, collector: collector, request_timeout: 30)
    socket = connect(port)
    socket.write(
      "POST /send-metrics HTTP/1.1\r\n" \
        "Host: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n\r\n" \
        "1\r\nx\r\n" \
        "10\r\npartial",
    )
    assert_equal("x", collector.next_value)

    Timeout.timeout(2) { server.stop }
    replacement = TCPServer.new("127.0.0.1", port)
    replacement.close
    @servers.delete(server)
  end

  def test_tls
    Dir.mktmpdir do |directory|
      cert_file, key_file = write_certificate(directory)
      port = free_port
      start_server(
        port: port,
        collector: RecordingCollector.new,
        tls_cert_file: cert_file,
        tls_key_file: key_file,
      )

      tcp = TCPSocket.new("127.0.0.1", port)
      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      socket = OpenSSL::SSL::SSLSocket.new(tcp, context)
      socket.sync_close = true
      socket.connect
      @sockets << socket
      socket.write("GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      status, _, body = read_response(socket)
      assert_equal([200, "PONG"], [status, body])
    end
  end

  def test_ipv4_ipv6_and_any_wildcard
    port = free_port
    server = start_server(port: port, bind: "127.0.0.1", collector: RecordingCollector.new)
    assert_ping(port, "127.0.0.1")
    server.stop
    @servers.delete(server)

    return unless ipv6_available?

    port = free_port("::1")
    server = start_server(port: port, bind: "::1", collector: RecordingCollector.new)
    assert_ping(port, "::1")
    server.stop
    @servers.delete(server)

    port = free_dual_stack_port
    start_server(port: port, bind: "ANY", collector: RecordingCollector.new)
    assert_ping(port, "127.0.0.1")
    assert_ping(port, "::1")
  end

  def test_body_parser_errors_escape_metrics_handler_and_force_close
    collector = RecordingCollector.new
    port = free_port
    start_server(port: port, collector: collector)
    socket = connect(port)
    socket.write(
      "POST /send-metrics HTTP/1.1\r\n" \
        "Host: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n\r\n" \
        "1\r\nx\r\nZ\r\n",
    )

    assert_equal("x", collector.next_value)
    status, headers, = read_response(socket)
    assert_equal(400, status)
    assert_equal("close", headers["connection"])
    assert_equal("", Timeout.timeout(1) { socket.read })
  end

  def test_route_method_semantics_and_options
    collector = RecordingCollector.new
    port = free_port
    start_server(port: port, collector: collector)

    assert_equal(
      200,
      raw_request(
        port,
        "HEAD /metrics HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        read_body: false,
      ).first,
    )
    assert_equal(
      200,
      raw_request(
        port,
        "HEAD /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        read_body: false,
      ).first,
    )

    %w[POST PUT].each do |method|
      status, =
        raw_request(
          port,
          "#{method} /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx",
        )
      assert_equal(200, status)
      assert_equal("x", collector.next_value)
    end

    {
      "POST /metrics" => "GET, HEAD, OPTIONS",
      "GET /send-metrics" => "POST, PUT, OPTIONS",
      "DELETE /ping" => "GET, HEAD, OPTIONS",
      "BREW /metrics" => "GET, HEAD, OPTIONS",
    }.each do |request_line, allow|
      status, headers, =
        raw_request(
          port,
          "#{request_line} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        )
      assert_equal(405, status)
      assert_equal(allow, headers["allow"])
    end

    {
      "/metrics" => "GET, HEAD, OPTIONS",
      "/ping" => "GET, HEAD, OPTIONS",
      "/send-metrics" => "POST, PUT, OPTIONS",
      "*" => "GET, HEAD, POST, PUT, OPTIONS",
    }.each do |target, allow|
      status, headers, =
        raw_request(
          port,
          "OPTIONS #{target} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        )
      assert_equal(200, status)
      assert_equal(allow, headers["allow"])
    end
  end

  def test_host_method_token_options_star_and_connect_validation
    port = free_port
    start_server(port: port, collector: RecordingCollector.new)

    invalid_requests = [
      "GET /ping HTTP/1.1\r\nConnection: close\r\n\r\n",
      "GET /ping HTTP/1.1\r\nHost: one\r\nHost: two\r\nConnection: close\r\n\r\n",
      "GET /ping HTTP/1.1\r\nHost: user@localhost\r\nConnection: close\r\n\r\n",
      "GET /ping HTTP/1.1\r\nHost: bad..host\r\nConnection: close\r\n\r\n",
      "GET /ping HTTP/1.1\r\nHost: localhost:99999\r\nConnection: close\r\n\r\n",
      "GE@T /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
      "GET * HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    ]
    invalid_requests.each { |request| assert_equal(400, raw_request(port, request).first, request) }

    status, headers, =
      raw_request(
        port,
        "CONNECT localhost:443 HTTP/1.1\r\nHost: localhost:443\r\nConnection: close\r\n\r\n",
      )
    assert_equal(405, status)
    assert_equal("GET, HEAD, POST, PUT, OPTIONS", headers["allow"])
    assert_equal(200, raw_request(port, "GET /ping HTTP/1.0\r\nConnection: close\r\n\r\n").first)
  end

  def test_realm_is_escaped_and_control_characters_are_rejected
    Dir.mktmpdir do |directory|
      auth_file = File.join(directory, "htpasswd")
      File.write(auth_file, "scraper:#{"secret".crypt("pe")}\n")
      assert_raises(ArgumentError) do
        PrometheusExporter::Server::WebServer.new(
          port: free_port,
          bind: "127.0.0.1",
          collector: RecordingCollector.new,
          auth: auth_file,
          realm: "metrics\r\nX-Injected: yes",
        )
      end

      port = free_port
      start_server(
        port: port,
        collector: RecordingCollector.new,
        auth: auth_file,
        realm: 'metrics \\ "private"',
      )
      _, headers, = raw_get(port, "/metrics")
      assert_equal('Basic realm="metrics \\\\ \\"private\\""', headers["www-authenticate"])
    end
  end

  def test_invalid_application_response_headers_are_never_serialized
    [
      ["Bad Name", "safe"],
      ["X-Test", "safe\r\nX-Injected: yes"],
      ["X-Test", "bad\u0001value"],
      %w[Transfer-Encoding chunked],
    ].each do |name, value|
      port = free_port
      server =
        start_http_server(port: port) do
          response = PrometheusExporter::Server::HTTP::Response.new
          response[name] = value
          response
        end
      status, headers, body = raw_get(port, "/")
      assert_equal(500, status)
      refute(headers.key?("x-injected"))
      assert_equal("Internal Server Error\n", body)
      server.shutdown
      @http_servers.delete(server)
    end
  end

  def test_body_forbidden_statuses_never_serialize_payloads
    [101, 204, 205, 304].each do |response_status|
      port = free_port
      server =
        start_http_server(port: port) do
          response =
            PrometheusExporter::Server::HTTP::Response.new(
              status: response_status,
              body: "forbidden",
            )
          response["Transfer-Encoding"] = "chunked"
          response
        end

      status, headers, body = raw_get(port, "/")
      assert_equal(response_status, status)
      assert_equal("", body)
      refute(headers.key?("transfer-encoding"))
      if response_status == 205
        assert_equal("0", headers["content-length"])
      else
        refute(headers.key?("content-length"))
      end

      server.shutdown
      @http_servers.delete(server)
    end
  end

  def test_custom_exception_status_is_safe
    port = free_port
    start_server(port: port, collector: StatusErrorCollector.new(429))
    status_line =
      raw_request(
        port,
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx",
        include_status_line: true,
      ).last
    assert_match(%r{\AHTTP/1\.1 429 Too Many Requests\r\n}, status_line)

    port = free_port
    start_server(port: port, collector: StatusErrorCollector.new(599))
    status_line =
      raw_request(
        port,
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx",
        include_status_line: true,
      ).last
    assert_match(%r{\AHTTP/1\.1 599 Unknown Status\r\n}, status_line)

    [99, 600, "not-a-status"].each do |invalid_status|
      port = free_port
      start_server(port: port, collector: StatusErrorCollector.new(invalid_status))
      status, =
        raw_request(
          port,
          "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx",
        )
      assert_equal(500, status)
    end
  end

  def test_lifecycle_has_no_prestart_listener_and_reports_bind_failure
    port = free_port
    server =
      PrometheusExporter::Server::WebServer.new(
        port: port,
        bind: "127.0.0.1",
        collector: RecordingCollector.new,
      )
    http_server = server.instance_variable_get(:@server)
    assert_empty(http_server.listeners)
    probe = TCPServer.new("127.0.0.1", port)
    probe.close

    blocker = TCPServer.new("127.0.0.1", port)
    assert_raises(Errno::EADDRINUSE) { server.start }
    assert_empty(http_server.listeners)
    blocker.close

    stopped =
      PrometheusExporter::Server::WebServer.new(
        port: free_port,
        bind: "127.0.0.1",
        collector: RecordingCollector.new,
      )
    stopped.stop
    assert_raises(RuntimeError) { stopped.start }
  ensure
    blocker&.close
  end

  def test_shutdown_can_win_startup_handshake_without_start_after_shutdown
    port = free_port
    server =
      PrometheusExporter::Server::HTTP::Server.new(
        bind: "127.0.0.1",
        port: port,
        logger: Logger.new(File::NULL),
      ) { PrometheusExporter::Server::HTTP::Response.new }
    @http_servers << server
    entered = Queue.new
    release = Queue.new
    original_accept_main = server.method(:accept_main)
    server.define_singleton_method(:accept_main) do
      entered << true
      release.pop
      original_accept_main.call
    end

    start_result = Queue.new
    starter =
      Thread.new do
        server.start
        start_result << :started
      rescue StandardError => e
        start_result << e
      end
    Timeout.timeout(1) { entered.pop }
    stopper = Thread.new { server.shutdown }
    wait_for_http_state(server, :stopping)
    release << true
    starter.join
    stopper.join

    result = start_result.pop
    assert_instance_of(RuntimeError, result)
    assert_match(/shut down during startup/, result.message)
    assert_raises(RuntimeError) { server.start }
    replacement = TCPServer.new("127.0.0.1", port)
    replacement.close
  end

  def test_shutdown_wins_before_published_client_can_process
    collector = RecordingCollector.new
    port = free_port
    server = start_server(port: port, collector: collector, shutdown_timeout: 0.5)
    http_server = server.instance_variable_get(:@server)
    entered = Queue.new
    release = Queue.new
    original_client_main = http_server.method(:client_main)
    http_server.define_singleton_method(:client_main) do |socket|
      entered << true
      release.pop
      original_client_main.call(socket)
    end

    socket = connect(port)
    socket.write("POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\nx")
    Timeout.timeout(1) { entered.pop }
    stopper = Thread.new { server.stop }
    wait_for_http_state(http_server, :stopping)
    release << true
    stopper.join

    assert_empty(collector.values)
    replacement = TCPServer.new("127.0.0.1", port)
    replacement.close
    @servers.delete(server)
  end

  def test_shutdown_timeout_bounds_blocked_application
    collector = BlockingCollector.new
    port = free_port
    timeout = 0.05
    server = start_server(port: port, collector: collector, shutdown_timeout: timeout)
    socket = connect(port)
    socket.write("POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\nx")
    Timeout.timeout(1) { collector.entered.pop }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    server.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator(elapsed, :>=, timeout * 0.8)
    assert_operator(elapsed, :<, timeout + 0.1)
    replacement = TCPServer.new("127.0.0.1", port)
    replacement.close
    @servers.delete(server)
  end

  def test_write_timeout_releases_only_client_slot_from_slow_reader
    collector = LargeResponseCollector.new(32 * 1024 * 1024)
    port = free_port
    start_server(
      port: port,
      collector: collector,
      max_clients: 1,
      write_timeout: 0.05,
      shutdown_timeout: 0.1,
    )
    slow = connect(port)
    slow.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 1024)
    slow.write(
      "GET /metrics HTTP/1.1\r\n" \
        "Host: localhost\r\n" \
        "Accept-Encoding: identity\r\n" \
        "Connection: close\r\n\r\n",
    )
    Timeout.timeout(1) { collector.rendered.pop }

    second = connect(port)
    second.write("GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    status, _, body = Timeout.timeout(1) { read_response(second) }
    assert_equal([200, "PONG"], [status, body])
  end

  def test_built_gem_loads_with_declared_dependencies_and_without_webrick
    refute(Object.const_defined?(:WEBrick, false))
    root = File.expand_path("../..", __dir__)
    logger_package = Gem::Specification.find_by_name("logger").cache_file
    assert_path_exists(logger_package)

    Dir.mktmpdir do |directory|
      gem_home = File.join(directory, "gems")
      package = File.join(directory, "prometheus_exporter.gem")
      build_output, build_status =
        Open3.capture2e(
          RbConfig.ruby,
          "-S",
          "gem",
          "build",
          "prometheus_exporter.gemspec",
          "--output",
          package,
          chdir: root,
        )
      assert(build_status.success?, build_output)

      env =
        ENV
          .each_key
          .grep(/\ABUNDLE/)
          .to_h { |name| [name, nil] }
          .merge("GEM_HOME" => gem_home, "GEM_PATH" => gem_home, "RUBYLIB" => nil, "RUBYOPT" => nil)
      [logger_package, package].each do |gem_file|
        output, status =
          Open3.capture2e(
            env,
            RbConfig.ruby,
            "-S",
            "gem",
            "install",
            "--local",
            "--no-document",
            "--install-dir",
            gem_home,
            "--ignore-dependencies",
            gem_file,
          )
        assert(status.success?, output)
      end

      script = <<~RUBY
        spec = Gem::Specification.find_by_name("prometheus_exporter")
        abort "logger is not a runtime dependency" unless spec.runtime_dependencies.any? { |dependency| dependency.name == "logger" }
        abort "webrick is still a dependency" if spec.runtime_dependencies.any? { |dependency| dependency.name == "webrick" }
        abort "webrick is installed" unless Gem::Specification.find_all_by_name("webrick").empty?
        require "prometheus_exporter"
        require "prometheus_exporter/server"
        abort "WEBrick constant defined" if Object.const_defined?(:WEBrick, false)
        abort "not loaded from installed gem" unless $LOADED_FEATURES.grep(/prometheus_exporter/).all? { |path| path.start_with?(ENV.fetch("GEM_HOME")) }
        puts "isolated built gem load ok"
      RUBY
      output, status = Open3.capture2e(env, RbConfig.ruby, "-e", script, chdir: directory)
      assert(status.success?, output)
      assert_equal("isolated built gem load ok\n", output)
    end
  end

  private

  def start_server(port:, collector:, bind: "127.0.0.1", **options)
    server =
      PrometheusExporter::Server::WebServer.new(
        { port: port, bind: bind, collector: collector }.merge(options),
      )
    @servers << server
    server.start
    server
  end

  def start_http_server(port:, **options, &handler)
    server =
      PrometheusExporter::Server::HTTP::Server.new(
        bind: "127.0.0.1",
        port: port,
        logger: Logger.new(File::NULL),
        **options,
        &handler
      )
    @http_servers << server
    server.start
    server
  end

  def connect(port, host = "127.0.0.1")
    socket = TCPSocket.new(host, port)
    @sockets << socket
    socket
  end

  def raw_get(port, path, request_headers = {}, host: "127.0.0.1")
    headers = { "Host" => "localhost", "Connection" => "close" }.merge(request_headers)
    wire_headers = headers.map { |name, value| "#{name}: #{value}\r\n" }.join
    raw_request(port, "GET #{path} HTTP/1.1\r\n#{wire_headers}\r\n", host: host)
  end

  def raw_request(port, request, host: "127.0.0.1", read_body: true, include_status_line: false)
    socket = connect(port, host)
    socket.write(request)
    read_response(socket, read_body: read_body, include_status_line: include_status_line)
  ensure
    socket&.close
  end

  def read_response(socket, read_body: true, include_status_line: false)
    status_line = Timeout.timeout(2) { socket.gets }
    raise "connection closed without response" unless status_line

    status = status_line.split(" ", 3)[1].to_i
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    length = Integer(headers.fetch("content-length", "0"), 10)
    body = !read_body || length.zero? ? "" : socket.read(length)
    response = [status, headers, body]
    response << status_line if include_status_line
    response
  end

  def assert_ping(port, host = "127.0.0.1")
    status, _, body = raw_get(port, "/ping", host: host)
    assert_equal([200, "PONG"], [status, body])
  end

  def wait_for_http_state(server, expected)
    mutex = server.instance_variable_get(:@mutex)
    state_changed = server.instance_variable_get(:@state_changed)
    Timeout.timeout(1) do
      mutex.synchronize do
        state_changed.wait(mutex) while server.instance_variable_get(:@state) != expected
      end
    end
  end

  def free_port(host = "127.0.0.1")
    server = TCPServer.new(host, 0)
    server.addr[1]
  ensure
    server&.close
  end

  def ipv6_available?
    server = TCPServer.new("::1", 0)
    true
  rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT
    false
  ensure
    server&.close
  end

  def free_dual_stack_port
    loop do
      port = free_port
      server = TCPServer.new("::1", port)
      server.close
      return port
    rescue Errno::EADDRINUSE
      next
    end
  end

  def write_certificate(directory)
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

    cert_file = File.join(directory, "cert.pem")
    key_file = File.join(directory, "key.pem")
    File.write(cert_file, certificate.to_pem)
    File.write(key_file, key.to_pem)
    [cert_file, key_file]
  end
end
