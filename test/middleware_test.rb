# frozen_string_literal: true

require 'minitest/stub_const'
require_relative 'test_helper'
require 'rack/test'
require 'prometheus_exporter/middleware'

class PrometheusExporterMiddlewareTest < Minitest::Test
  include Rack::Test::Methods

  attr_reader :app

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

  def configure_middleware(overrides = {})
    config = { client: client, instrument: :alias_method }.merge(overrides)
    @app = PrometheusExporter::Middleware.new(inner_app, config)
    def @app.request_start
      1234567891.123
    end
  end

  def assert_valid_headers_response(delta = 0.5)
    configure_middleware
    get '/'
    assert last_response.ok?
    refute_nil client.last_send
    refute_nil client.last_send[:queue_time]
    assert_in_delta 1, client.last_send[:queue_time], delta
  end

  def assert_invalid_headers_response
    configure_middleware
    get '/'
    assert last_response.ok?
    refute_nil client.last_send
    assert_nil client.last_send[:queue_time]
  end

  def test_converting_apache_request_start
    configure_middleware
    now_microsec = '1234567890123456'
    header 'X-Request-Start', "t=#{now_microsec}"
    assert_valid_headers_response
  end

  def test_converting_nginx_request_start
    configure_middleware
    now = '1234567890.123'
    header 'X-Request-Start', "t=#{now}"
    assert_valid_headers_response
  end

  def test_request_start_in_wrong_format
    configure_middleware
    header 'X-Request-Start', ""
    assert_invalid_headers_response
  end

  def test_converting_amzn_trace_id_start
    configure_middleware
    now = '1234567890'
    header 'X-Amzn-Trace-Id', "Root=1-#{now.to_i.to_s(16)}-abc123"
    assert_valid_headers_response
  end

  def test_amzn_trace_id_in_wrong_format
    configure_middleware
    header 'X-Amzn-Trace-Id', ""
    assert_invalid_headers_response
  end

  def test_redis_5_call_patching
    RedisValidationMiddleware.reset!
    configure_middleware

    # protocol 2 is the old redis protocol, it uses no preamble so you don't leak HELLO
    # calls
    redis_config = RedisClient.config(host: "127.0.0.1", port: 10, protocol: 2)
    redis = redis_config.new_pool(timeout: 0.5, size: 1)
    PrometheusExporter::Instrumentation::MethodProfiler.start
    redis.call("PING") # => "PONG"
    redis.call("PING") # => "PONG"
    results = PrometheusExporter::Instrumentation::MethodProfiler.stop
    assert(2, results[:redis][:calls])

    assert_equal(2, RedisValidationMiddleware.call_calls)
    assert_equal(0, RedisValidationMiddleware.call_pipelined_calls)
  end

  def test_redis_5_call_pipelined_patching
    RedisValidationMiddleware.reset!
    configure_middleware

    # protocol 2 is the old redis protocol, it uses no preamble so you don't leak HELLO
    # calls
    redis_config = RedisClient.config(host: "127.0.0.1", port: 10, protocol: 2)
    redis = redis_config.new_pool(timeout: 0.5, size: 1)
    PrometheusExporter::Instrumentation::MethodProfiler.start
    redis.pipelined do |pipeline|
      pipeline.call("PING") # => "PONG"
      pipeline.call("PING") # => "PONG"
    end

    assert_equal(0, RedisValidationMiddleware.call_calls)
    assert_equal(1, RedisValidationMiddleware.call_pipelined_calls)

    results = PrometheusExporter::Instrumentation::MethodProfiler.stop
    assert_equal(1, results[:redis][:calls])
  end

  def test_patch_called_with_prepend_instrument
    Object.stub_const(:Redis, Module) do
      ::Redis.stub_const(:Client) do
        mock = Minitest::Mock.new
        mock.expect :call, nil, [Redis::Client, Array, :redis], instrument: :prepend
        ::PrometheusExporter::Instrumentation::MethodProfiler.stub(:patch, mock) do
          configure_middleware(instrument: :prepend)
        end
        mock.verify
      end
    end

    Object.stub_const(:PG, Module) do
      ::PG.stub_const(:Connection) do
        mock = Minitest::Mock.new
        mock.expect :call, nil, [PG::Connection, Array, :sql], instrument: :prepend
        ::PrometheusExporter::Instrumentation::MethodProfiler.stub(:patch, mock) do
          configure_middleware(instrument: :prepend)
        end
        mock.verify
      end
    end

    Object.stub_const(:Mysql2, Module) do
      ::Mysql2.stub_consts({ Client: nil, Statement: nil, Result: nil }) do
        mock = Minitest::Mock.new
        mock.expect :call, nil, [Mysql2::Client, Array, :sql], instrument: :prepend
        mock.expect :call, nil, [Mysql2::Statement, Array, :sql], instrument: :prepend
        mock.expect :call, nil, [Mysql2::Result, Array, :sql], instrument: :prepend
        ::PrometheusExporter::Instrumentation::MethodProfiler.stub(:patch, mock) do
          configure_middleware(instrument: :prepend)
        end
        mock.verify
      end
    end

    Object.stub_const(:Dalli, Module) do
      ::Dalli.stub_const(:Client) do
        mock = Minitest::Mock.new
        mock.expect :call, nil, [Dalli::Client, Array, :memcache], instrument: :prepend
        ::PrometheusExporter::Instrumentation::MethodProfiler.stub(:patch, mock) do
          configure_middleware(instrument: :prepend)
        end
        mock.verify
      end
    end
  end

  def test_patch_called_with_alias_method_instrument
    Object.stub_const(:Redis, Module) do
      # must be less than version 5 for this instrumentation
      ::Redis.stub_const(:VERSION, '4.0.4') do
        ::Redis.stub_const(:Client) do
          mock = Minitest::Mock.new
          mock.expect :call, nil, [Redis::Client, Array, :redis], instrument: :alias_method
          ::PrometheusExporter::Instrumentation::MethodProfiler.stub(:patch, mock) do
            configure_middleware
          end
          mock.verify
        end
      end
    end

    Object.stub_const(:PG, Module) do
      ::PG.stub_const(:Connection) do
        mock = Minitest::Mock.new
        mock.expect :call, nil, [PG::Connection, Array, :sql], instrument: :alias_method
        ::PrometheusExporter::Instrumentation::MethodProfiler.stub(:patch, mock) do
          configure_middleware
        end
        mock.verify
      end
    end

    Object.stub_const(:Mysql2, Module) do
      ::Mysql2.stub_consts({ Client: nil, Statement: nil, Result: nil }) do
        mock = Minitest::Mock.new
        mock.expect :call, nil, [Mysql2::Client, Array, :sql], instrument: :alias_method
        mock.expect :call, nil, [Mysql2::Statement, Array, :sql], instrument: :alias_method
        mock.expect :call, nil, [Mysql2::Result, Array, :sql], instrument: :alias_method
        ::PrometheusExporter::Instrumentation::MethodProfiler.stub(:patch, mock) do
          configure_middleware
        end
        mock.verify
      end
    end

    Object.stub_const(:Dalli, Module) do
      ::Dalli.stub_const(:Client) do
        mock = Minitest::Mock.new
        mock.expect :call, nil, [Dalli::Client, Array, :memcache], instrument: :alias_method
        ::PrometheusExporter::Instrumentation::MethodProfiler.stub(:patch, mock) do
          configure_middleware(instrument: :alias_method)
        end
        mock.verify
      end
    end
  end
end
