# frozen_string_literal: true

require "minitest/stub_const"
require_relative "test_helper"
require "prometheus_exporter/client"
require "prometheus_exporter/instrumentation/sidekiq"

class PrometheusExporterSidekiqMiddlewareTest < Minitest::Test
  class FakeClient
  end

  def client
    @client ||= FakeClient.new
  end

  class FakeSidekiqMiddlewareChainEntry
    attr_reader :klass

    def initialize(klass, *args)
      @klass = klass
      @args = args
    end

    def make_new
      @klass.new(*@args)
    end
  end

  def test_oversized_metric_does_not_replace_job_error_in_ensure
    logs = StringIO.new
    real_client = PrometheusExporter::Client.new(max_record_size: 1, logger: Logger.new(logs))
    middleware = PrometheusExporter::Instrumentation::Sidekiq.new(client: real_client)

    Object.stub_const(:Sidekiq, Module) do
      ::Sidekiq.stub_const(:Shutdown, Class.new(StandardError)) do
        error =
          assert_raises(RuntimeError) do
            middleware.call(Object.new, {}, "default") { raise "job failed" }
          end
        assert_equal("job failed", error.message)
      end
    end

    assert_match(/dropping message.*maximum is 1 bytes/, logs.string)
  ensure
    real_client&.stop
  end

  def test_initiating_middlware
    middleware_entry =
      FakeSidekiqMiddlewareChainEntry.new(
        PrometheusExporter::Instrumentation::Sidekiq,
        { client: client },
      )
    assert_instance_of PrometheusExporter::Instrumentation::Sidekiq, middleware_entry.make_new
  end
end
