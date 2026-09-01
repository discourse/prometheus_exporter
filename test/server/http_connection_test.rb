# frozen_string_literal: true

require_relative "web_server_test_helper"

class SlowProcessCollector < DemoCollector
  attr_reader :started, :release

  def initialize
    super
    @started = Queue.new
    @release = Queue.new
  end

  def process(str)
    @started << true
    @release.pop
    super
  end
end

class PrometheusExporterHTTPConnectionTest < WebServerTestCase
  def test_bundled_client_reuses_request_after_short_header_deadline
    collector = DemoCollector.new
    _server, port = start_server(collector: collector, header_timeout: 0.1, body_read_timeout: 1)
    client = PrometheusExporter::Client.new(host: "127.0.0.1", port: port, thread_sleep: 0.001)
    @clients << client

    client.send_json "type" => "mem metric", "value" => 1
    assert_equal 1, JSON.parse(queue_pop(collector.processed))["value"]
    first_socket = client.instance_variable_get(:@socket)

    sleep 0.2
    assert_operator 0.2, :>, 0.1
    assert_operator 0.2, :<, PrometheusExporter::Client::MAX_SOCKET_AGE
    client.send_json "type" => "mem metric", "value" => 2

    assert_equal 2, JSON.parse(queue_pop(collector.processed))["value"]
    assert_same first_socket, client.instance_variable_get(:@socket)
  end

  def test_processes_each_http_chunk_before_the_upload_finishes
    collector = DemoCollector.new
    _server, port = start_server(collector: collector)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write(
      "POST /send-metrics HTTP/1.1\r\n" \
        "Host: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n\r\n",
    )

    first = JSON.dump("type" => "mem metric", "value" => 1)
    socket.write("#{first.bytesize.to_s(16)}\r\n#{first}\r\n")
    assert_equal first, queue_pop(collector.processed)

    second = JSON.dump("type" => "mem metric", "value" => 2)
    socket.write("#{second.bytesize.to_s(16)}\r\n#{second}\r\n")
    assert_equal second, queue_pop(collector.processed)

    socket.write("0\r\n\r\n")
    status, headers, body = read_response(socket)
    assert_equal 200, status
    assert_equal "OK", body
    assert_fixed_response(headers, body)
  ensure
    socket&.close
  end

  def test_header_and_single_chunk_read_deadlines
    _server, port = start_server(header_timeout: 0.2, body_read_timeout: 0.2)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write("GET /ping HTTP/1.1\r\nHost:")
    status, headers, body = read_response(socket)

    assert_equal 408, status
    assert_fixed_response(headers, body)

    socket.close
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write(
      "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n\r\n10\r\n{}",
    )
    status, = read_response(socket)
    assert_equal 408, status
  ensure
    socket&.close
  end

  def test_each_chunk_gets_a_fresh_body_read_deadline
    collector = DemoCollector.new
    _server, port = start_server(collector: collector, body_read_timeout: 0.5)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write(
      "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n\r\n",
    )
    payload = JSON.dump("type" => "mem metric", "value" => 1)
    socket.write("#{payload.bytesize.to_s(16)}\r\n#{payload}\r\n")
    assert_equal payload, queue_pop(collector.processed)

    sleep 0.3
    socket.write("#{payload.bytesize.to_s(16)}\r\n#{payload}\r\n")
    assert_equal payload, queue_pop(collector.processed)

    sleep 0.3
    socket.write("0\r\n\r\n")
    status, = read_response(socket)
    assert_equal 200, status
  ensure
    socket&.close
  end

  def test_collector_latency_does_not_expire_buffered_complete_chunks
    collector = SlowProcessCollector.new
    _server, port = start_server(collector: collector, body_read_timeout: 0.2)
    payload = JSON.dump("type" => "mem metric", "value" => 1)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write(
      "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\n" \
        "Transfer-Encoding: chunked\r\n\r\n" \
        "#{payload.bytesize.to_s(16)}\r\n#{payload}\r\n" \
        "#{payload.bytesize.to_s(16)}\r\n#{payload}\r\n0\r\n\r\n",
    )
    queue_pop(collector.started)
    sleep 0.4
    collector.release << true
    queue_pop(collector.started)
    collector.release << true

    status, = read_response(socket)
    assert_equal 200, status
    assert_equal 2, collector.processed.size
  ensure
    collector&.release&.push(true)
    socket&.close
  end

  def test_response_writes_are_nonblocking_and_bounded
    server, = start_server(write_timeout: 0.03)
    writer, reader = UNIXSocket.pair
    writer.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 1024)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    connection = server.instance_variable_get(:@listener).send(:build_connection, writer)
    connection.send(:write_response, 200, "x" * (2 * 1024 * 1024), {})
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1
  ensure
    writer&.close
    reader&.close
  end

  def test_rejects_oversized_headers_and_body_chunks
    _server, port = start_server(max_header_bytes: 96, max_body_chunk_bytes: 8)

    status, =
      raw_request(port, "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Large: #{"x" * 100}\r\n\r\n")
    assert_equal 431, status

    status, =
      raw_request(
        port,
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\n" \
          "Transfer-Encoding: chunked\r\n\r\n9\r\n",
      )
    assert_equal 413, status
  end

  def test_validates_byte_limits_as_positive_integers
    %i[max_header_bytes max_body_chunk_bytes].each do |option|
      [0, -1, 1.5, "10", false, nil].each do |value|
        options = { :port => free_port, :bind => "127.0.0.1", option => value }
        error = assert_raises(ArgumentError) { PrometheusExporter::Server::WebServer.new(options) }
        assert_match(/#{option} must be a positive integer/, error.message)
      end
    end
  end

  def test_rejects_malformed_or_ambiguous_requests
    _server, port = start_server
    requests = {
      400 => [
        "GET /ping HTTP/1.1\nHost: localhost\n\n",
        "GET http://localhost/ping HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /ping HTTP/1.1\r\n\r\n",
        "GET /ping HTTP/1.1\r\nHost: one\r\nHost: two\r\n\r\n",
        "GET /ping HTTP/1.1\r\nHost: invalid host\r\n\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        "POST /send-metrics HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n1;x=y\r\na\r\n0\r\n\r\n",
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Trailer: no\r\n\r\n",
      ],
      405 => ["POST /ping HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"],
      411 => ["POST /send-metrics HTTP/1.1\r\nHost: localhost\r\n\r\n"],
      417 => ["GET /ping HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\n\r\n"],
      505 => ["GET /ping HTTP/2.0\r\nHost: localhost\r\n\r\n"],
    }

    requests.each do |expected_status, raw_requests|
      raw_requests.each do |request|
        status, headers, body = raw_request(port, request)
        assert_equal expected_status, status, request.inspect
        assert_fixed_response(headers, body)
      end
    end

    status, headers, =
      raw_request(port, "POST /ping HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")
    assert_equal 405, status
    assert_equal "GET", headers["allow"]
  end

  def test_supports_a_bounded_content_length_upload
    collector = DemoCollector.new
    _server, port = start_server(collector: collector)
    json = JSON.dump("type" => "mem metric", "value" => 7)

    status, _headers, body =
      raw_request(
        port,
        "POST /send-metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: #{json.bytesize}\r\n\r\n#{json}",
      )

    assert_equal 200, status
    assert_equal "OK", body
    assert_equal json, queue_pop(collector.processed)
  end
end
