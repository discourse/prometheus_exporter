# frozen_string_literal: true

require "test_helper"
require 'rack/test'
require 'prometheus_exporter/middleware'

class PrometheusExporterMiddlewareTest < Minitest::Test
  include Rack::Test::Methods

  class FakeClient
    attr_reader :last_send

    def send_json(args)
      @last_send = args
    end
  end

  def client
    @client ||= FakeClient.new
  end

  def inner_app
    Proc.new do |env|
      [200, {}, "OK"]
    end
  end

  def now
    @now = Process.clock_gettime(Process::CLOCK_REALTIME)
  end

  def app
    @middleware ||= begin
      app = PrometheusExporter::Middleware.new(inner_app, client: client, instrument: true)
      def app.request_start
        1234567891.123
      end
      app
    end
  end

  def assert_valid_headers_response(delta = 0.5)
    get '/'
    assert last_response.ok?
    refute_nil client.last_send
    refute_nil client.last_send[:queue_time]
    assert_in_delta 1, client.last_send[:queue_time], delta
  end

  def assert_invalid_headers_response
    get '/'
    assert last_response.ok?
    refute_nil client.last_send
    assert_nil client.last_send[:queue_time]
  end

  def test_converting_apache_request_start
    now_microsec = '1234567890123456'
    header 'X-Request-Start', "t=#{now_microsec}"
    assert_valid_headers_response
  end

  def test_converting_nginx_request_start
    now = '1234567890.123'
    header 'X-Request-Start', "t=#{now}"
    assert_valid_headers_response
  end

  def test_request_start_in_wrong_format
    header 'X-Request-Start', ""
    assert_invalid_headers_response
  end

  def test_converting_amzn_trace_id_start
    now = '1234567890'
    header 'X-Amzn-Trace-Id', "Root=1-#{now.to_i.to_s(16)}-abc123"
    assert_valid_headers_response
  end

  def test_amzn_trace_id_in_wrong_format
    header 'X-Amzn-Trace-Id', ""
    assert_invalid_headers_response
  end

end
