# frozen_string_literal: true

require 'minitest/stub_const'
require_relative 'test_helper'
require 'prometheus_exporter/instrumentation/sidekiq'

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

  def test_initiating_middlware
    middleware_entry = FakeSidekiqMiddlewareChainEntry.new(
      PrometheusExporter::Instrumentation::Sidekiq, { client: client })
    assert_instance_of PrometheusExporter::Instrumentation::Sidekiq, middleware_entry.make_new
  end

end
