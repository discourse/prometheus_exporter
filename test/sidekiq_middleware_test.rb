# frozen_string_literal: true

require "minitest/stub_const"
require_relative "test_helper"
require "prometheus_exporter/instrumentation/sidekiq"
require "prometheus_exporter/client"

class PrometheusExporterSidekiqMiddlewareTest < Minitest::Test
  class FakeClient
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send_json(message)
      @messages << message
    end
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

  def test_initiating_middlware
    middleware_entry =
      FakeSidekiqMiddlewareChainEntry.new(
        PrometheusExporter::Instrumentation::Sidekiq,
        { client: client },
      )
    assert_instance_of PrometheusExporter::Instrumentation::Sidekiq, middleware_entry.make_new
  end

  def test_reports_original_job_name_for_sidekiq_8_active_job
    assert_reported_job_name("Sidekiq::ActiveJob::Wrapper", "ExampleJob")
  end

  def test_reports_original_job_name_for_legacy_active_job
    assert_reported_job_name("ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper", "ExampleJob")
  end

  def test_preserves_native_sidekiq_job_name
    assert_reported_job_name("ExampleWorker", "ExampleWorker")
  end

  private

  def assert_reported_job_name(wrapper_class_name, expected_name)
    worker_class = Class.new
    message = { "class" => wrapper_class_name, "wrapped" => "ExampleJob" }
    middleware = PrometheusExporter::Instrumentation::Sidekiq.new(client: client)

    worker_class.stub(:to_s, wrapper_class_name) do
      assert_equal :result, middleware.call(worker_class.new, message, "default") { :result }
    end

    PrometheusExporter::Client.stub(:default, client) do
      Object.stub(:const_get, worker_class) do
        PrometheusExporter::Instrumentation::Sidekiq.death_handler.call(message, StandardError.new)
      end
    end

    assert_equal 2, client.messages.size
    assert_equal expected_name, client.messages[0][:name]
    assert_equal true, client.messages[0][:success]
    assert_equal expected_name, client.messages[1][:name]
    assert_equal true, client.messages[1][:dead]
  end
end
