# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/server"
require "prometheus_exporter/client"
require "socket"
require "tempfile"
require "timeout"

class DemoCollector
  attr_reader :processed

  def initialize
    @gauge = PrometheusExporter::Metric::Gauge.new "memory", "amount of memory"
    @processed = Queue.new
  end

  def process(string)
    @processed << string
    metric = JSON.parse(string)
    @gauge.observe(metric["value"]) if metric["type"] == "mem metric"
  end

  def prometheus_metrics_text
    @gauge.to_prometheus_text
  end
end

class WebServerTestCase < Minitest::Test
  def setup
    PrometheusExporter::Metric::Base.default_prefix = ""
    @servers = []
    @clients = []
    @files = []
  end

  def teardown
    @clients.each do |client|
      client.stop
    rescue StandardError
      nil
    end
    @servers.reverse_each do |server|
      server.stop
    rescue StandardError
      nil
    end
    @files.each(&:close!)
  end

  private

  def start_server(**options)
    port = options.delete(:port) || free_port(options[:bind] || "127.0.0.1")
    options[:bind] ||= "127.0.0.1"
    server = PrometheusExporter::Server::WebServer.new(options.merge(port: port))
    @servers << server
    server.start
    [server, port]
  end

  def free_port(host = "127.0.0.1")
    server = TCPServer.new(host, 0)
    server.local_address.ip_port
  ensure
    server&.close
  end

  def raw_request(port, request, host: "127.0.0.1")
    socket = TCPSocket.new(host, port)
    socket.write(request)
    read_response(socket)
  ensure
    socket&.close
  end

  def read_response(socket)
    raw = socket.read
    header_text, body = raw.split("\r\n\r\n", 2)
    refute_nil body, "response had no header terminator: #{raw.inspect}"
    lines = header_text.split("\r\n")
    status_line = lines.shift
    status_match = /\AHTTP\/1\.1 (\d{3}) (.*)\z/.match(status_line)
    refute_nil status_match, "malformed response status line: #{status_line.inspect}"
    status = status_match[1].to_i
    reason = status_match[2]
    headers =
      lines.to_h do |line|
        name, value = line.split(":", 2)
        [name.downcase, value.strip]
      end
    [status, headers, body, reason]
  end

  def assert_fixed_response(headers, body)
    assert_equal body.bytesize.to_s, headers["content-length"]
    assert_equal "close", headers["connection"]
    refute headers.key?("transfer-encoding")
  end

  def queue_pop(queue, timeout: 1)
    Timeout.timeout(timeout) { queue.pop }
  end

  def tempfile
    file = Tempfile.new("prometheus-exporter-test")
    @files << file
    file
  end
end
