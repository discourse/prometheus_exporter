# frozen_string_literal: true

require_relative "web_server_test_helper"
require "base64"
require "net/http"

class SlowCollector < DemoCollector
  def prometheus_metrics_text
    sleep 0.2
    super
  end
end

class CollectorStatusError < StandardError
  attr_reader :status_code

  def initialize(status_code, message)
    @status_code = status_code
    super(message)
  end
end

class ErrorCollector < DemoCollector
  def initialize(status_code, message = "invalid metrics")
    super()
    @status_code = status_code
    @message = message
  end

  def process(_str)
    raise CollectorStatusError.new(@status_code, @message)
  end
end

class PrometheusExporterWebServerTest < WebServerTestCase
  def test_client_chunked_uploads_are_processed
    assert PrometheusExporter.has_oj?
    assert_equal 100, PrometheusExporter::Server::WebServer::DEFAULT_MAX_CONNECTIONS
    assert_operator(
      PrometheusExporter::Server::WebServer::DEFAULT_BODY_READ_TIMEOUT,
      :>,
      PrometheusExporter::Client::MAX_SOCKET_AGE,
    )

    collector = DemoCollector.new
    server, port = start_server(collector: collector)
    clients =
      %i[oj json].map do |serializer|
        PrometheusExporter::Client.new(
          host: "127.0.0.1",
          port: port,
          thread_sleep: 0.001,
          json_serializer: serializer,
        )
      end
    clients << PrometheusExporter::Client.new(host: "127.0.0.1", port: port, thread_sleep: 0.001)
    @clients.concat(clients)

    clients.each_with_index do |client, index|
      client.send_json "type" => "mem metric", "value" => 150 + index
    end

    assert TestHelper.wait_for(2) { collector.processed.size == 3 }
    assert_equal 3, collector.processed.size
    assert_match(/memory 15[0-2]/, collector.prometheus_metrics_text)
    assert_instance_of PrometheusExporter::Server::WebServer, server
  end

  def test_standard_client_metrics_keep_their_aggregation_behavior
    server, port = start_server
    client = PrometheusExporter::Client.new(host: "127.0.0.1", port: port, thread_sleep: 0.001)
    @clients << client
    gauge = client.register(:gauge, "my_gauge", "some gauge")
    counter = client.register(:counter, "my_counter", "some counter")

    gauge.observe(2, abcd: 1)
    counter.observe(1)
    counter.observe(3)
    gauge.observe(92, abcd: 1)

    expected = <<~TEXT
      # HELP my_gauge some gauge
      # TYPE my_gauge gauge
      my_gauge{abcd="1"} 92

      # HELP my_counter some counter
      # TYPE my_counter counter
      my_counter 4
    TEXT
    assert TestHelper.wait_for(2) { server.collector.prometheus_metrics_text == expected }
    assert_equal expected, server.collector.prometheus_metrics_text
  end

  def test_ping_and_metrics_responses_have_fixed_lengths_and_close
    collector = DemoCollector.new
    collector.process(JSON.dump("type" => "mem metric", "value" => 42))
    _server, port = start_server(collector: collector)

    status, headers, body = raw_request(port, "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_equal 200, status
    assert_equal "PONG", body
    assert_fixed_response(headers, body)

    status, headers, body =
      raw_request(
        port,
        "GET /metrics HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: identity\r\n\r\n",
      )
    assert_equal 200, status
    assert_includes body, "memory 42"
    assert_fixed_response(headers, body)
  end

  def test_net_http_interoperability_and_exact_not_found_response
    collector = DemoCollector.new
    collector.process(JSON.dump("type" => "mem metric", "value" => 43))
    _server, port = start_server(collector: collector)

    Net::HTTP.start("127.0.0.1", port) do |http|
      ping = http.get("/ping")
      assert_equal "200", ping.code
      assert_equal "PONG", ping.body

      metrics = http.get("/metrics", "Accept-Encoding" => "identity")
      assert_equal "200", metrics.code
      assert_includes metrics.body, "memory 43"

      missing = http.get("/missing")
      assert_equal "404", missing.code
      assert_equal(
        "Not Found! The Prometheus Ruby Exporter only listens on /ping, /metrics and /send-metrics",
        missing.body,
      )
    end
  end

  def test_metrics_gzip_negotiation_and_vary_header
    collector = DemoCollector.new
    collector.process(JSON.dump("type" => "mem metric", "value" => 99))
    _server, port = start_server(collector: collector)

    {
      "br, gzip" => true,
      "*" => true,
      "gzip;q=0, *;q=1" => false,
      "gzip;q=0.5, *;q=0" => true,
      "GZip ; Q = 1.000" => true,
      "gzip;q=0.000" => false,
      "gzip;q=1.001" => false,
      "gzip;q=.5" => false,
      "gzip;q=0.0000" => false,
      "br, *;q=0" => false,
    }.each do |accept_encoding, compressed|
      status, headers, body =
        raw_request(
          port,
          "GET /metrics?source=test HTTP/1.1\r\nHost: localhost\r\n" \
            "Accept-Encoding: #{accept_encoding}\r\n\r\n",
        )

      assert_equal 200, status
      assert_equal "Accept-Encoding", headers["vary"]
      if compressed
        assert_equal "gzip", headers["content-encoding"], accept_encoding
        assert_includes Zlib::GzipReader.new(StringIO.new(body)).read, "memory 99"
      else
        refute headers.key?("content-encoding"), accept_encoding
        assert_includes body, "memory 99"
      end
      assert_fixed_response(headers, body)
    end
  end

  def test_metrics_collection_timeout_does_not_hang_the_endpoint
    _server, port = start_server(collector: SlowCollector.new, timeout: 0.02)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, _headers, body = raw_request(port, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 200, status
    assert_operator elapsed, :<, 0.15
    assert_includes body, "collector_working 0"
  end

  def test_basic_auth_uses_htpasswd_crypt_format
    auth_file = tempfile
    password_hash = "test_password".crypt("xy")
    auth_file.write("test_user:#{password_hash}\n")
    auth_file.flush
    _server, port = start_server(auth: auth_file.path, realm: "Metrics Realm")

    status, headers, body = raw_request(port, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_equal 401, status
    assert_equal "Unauthorized", body
    assert_equal 'Basic realm="Metrics Realm"', headers["www-authenticate"]

    credentials = Base64.strict_encode64("test_user:test_password")
    status, _headers, body =
      raw_request(
        port,
        "GET /metrics HTTP/1.1\r\nHost: localhost\r\nAuthorization: Basic #{credentials}\r\n\r\n",
      )
    assert_equal 200, status
    assert_includes body, "collector_working"

    bad_credentials = Base64.strict_encode64("test_user:wrong")
    status, =
      raw_request(
        port,
        "GET /metrics HTTP/1.1\r\nHost: localhost\r\nAuthorization: Basic #{bad_credentials}\r\n\r\n",
      )
    assert_equal 401, status

    status, = raw_request(port, "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_equal 200, status
  end

  def test_auth_realm_cannot_inject_response_headers
    auth_file = tempfile
    auth_file.write("test_user:#{"password".crypt("xy")}\n")
    auth_file.flush
    realm = "safe\"\r\nX-Injected: yes\\tail"
    _server, port = start_server(auth: auth_file.path, realm: realm)

    status, headers, = raw_request(port, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

    assert_equal 401, status
    assert_equal 'Basic realm="safe\\"X-Injected: yes\\\\tail"', headers["www-authenticate"]
    refute headers.key?("x-injected")
  end

  def test_collector_errors_return_an_error_and_are_counted
    _server, port = start_server(collector: DemoCollector.new)
    invalid_json = "not-json"
    request =
      "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n\r\n" \
        "#{invalid_json.bytesize.to_s(16)}\r\n#{invalid_json}\r\n0\r\n\r\n"

    status, _headers, body = raw_request(port, request)
    assert_equal 500, status
    assert_includes body, "Bad Metrics"

    _status, _headers, metrics =
      raw_request(port, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_includes metrics, "collector_metrics_total 1"
    assert_includes metrics, "collector_sessions_total 1"
    assert_includes metrics, "collector_bad_metrics_total 1"
  end

  def test_collector_exception_status_is_validated_and_cannot_inject_response
    cases = [
      [422, 422, "Unprocessable Entity"],
      [499, 499, "Error"],
      [599, 599, "Error"],
      [399, 500, "Internal Server Error"],
      [600, 500, "Internal Server Error"],
      [422.0, 500, "Internal Server Error"],
      ["422\r\nX-Injected: yes", 500, "Internal Server Error"],
    ]

    cases.each do |status_code, expected, expected_reason|
      collector = ErrorCollector.new(status_code, "bad\r\nX-Body: body-only")
      _server, port = start_server(collector: collector)
      request =
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\n" \
          "Content-Length: 2\r\n\r\n{}"

      status, headers, body, reason = raw_request(port, request)
      assert_equal expected, status
      assert_equal expected_reason, reason
      refute headers.key?("x-injected")
      refute headers.key?("x-body")
      assert_includes body, "X-Body: body-only"
    end
  end
end
