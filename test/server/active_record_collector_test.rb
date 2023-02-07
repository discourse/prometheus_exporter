# frozen_string_literal: true

require_relative '../test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusActiveRecordCollectorTest < Minitest::Test
  include CollectorHelper

  def collector
    @collector ||= PrometheusExporter::Server::ActiveRecordCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      "type" => "active_record",
      "pid" => "1000",
      "hostname" => "localhost",
      "connections" => 50,
      "busy" => 20,
      "dead" => 10,
      "idle" => 20,
      "waiting" => 0,
      "size" => 120
    )
    metrics = collector.metrics
    assert_equal 6, metrics.size
  end

  def test_collecting_metrics_with_custom_labels
    collector.collect(
      "type" => "active_record",
      "pid" => "1000",
      "hostname" => "localhost",
      "connections" => 50,
      "busy" => 20,
      "dead" => 10,
      "idle" => 20,
      "waiting" => 0,
      "size" => 120,
      "metric_labels" => {
        "service" => "service1"
      }
    )

    metrics = collector.metrics
    assert_equal 6, metrics.size
    assert(metrics.first.metric_text.include?('active_record_connection_pool_connections{service="service1",pid="1000",hostname="localhost"} 50'))
  end

  def test_collecting_metrics_with_client_default_labels
    collector.collect(
      "type" => "active_record",
      "pid" => "1000",
      "hostname" => "localhost",
      "connections" => 50,
      "busy" => 20,
      "dead" => 10,
      "idle" => 20,
      "waiting" => 0,
      "size" => 120,
      "metric_labels" => {
        "service" => "service1"
      },
      "custom_labels" => {
        "environment" => "test"
      }
    )

    metrics = collector.metrics
    assert_equal 6, metrics.size
    assert(metrics.first.metric_text.include?('active_record_connection_pool_connections{service="service1",pid="1000",hostname="localhost",environment="test"} 50'))
  end

  def test_collecting_metrics_for_multiple_pools
    collector.collect(
      "type" => "active_record",
      "hostname" => "localhost",
      "pid" => "1000",
      "connections" => 50,
      "busy" => 20,
      "dead" => 10,
      "idle" => 20,
      "waiting" => 0,
      "size" => 120,
      "metric_labels" => {
        "pool_name" => "primary"
      }
    )
    collector.collect(
      "type" => "active_record",
      "hostname" => "localhost",
      "pid" => "1000",
      "connections" => 5,
      "busy" => 2,
      "dead" => 1,
      "idle" => 2,
      "waiting" => 0,
      "size" => 12,
      "metric_labels" => {
        "pool_name" => "other"
      }
    )

    metrics = collector.metrics
    assert_equal 6, metrics.size
    assert(metrics.first.metric_text.include?('active_record_connection_pool_connections{pool_name="primary",pid="1000",hostname="localhost"} 50'))
    assert(metrics.first.metric_text.include?('active_record_connection_pool_connections{pool_name="other",pid="1000",hostname="localhost"} 5'))
  end

  def test_metrics_deduplication
    data = {
      "pid" => "1000",
      "hostname" => "localhost",
      "metric_labels" => { "pool_name" => "primary" },
      "connections" => 100
    }

    collector.collect(data)
    collector.collect(data.merge("connections" => 200))
    collector.collect(data.merge("pid" => "2000", "connections" => 300))
    collector.collect(data.merge("pid" => "3000", "connections" => 400))
    collector.collect(data.merge("hostname" => "localhost2", "pid" => "2000", "connections" => 500))

    metrics = collector.metrics
    metrics_lines = metrics.map(&:metric_text).join.split("\n")

    assert_equal 1, metrics.size
    assert_equal [
      'active_record_connection_pool_connections{pool_name="primary",pid="1000"} 200',
      'active_record_connection_pool_connections{pool_name="primary",pid="2000"} 300',
      'active_record_connection_pool_connections{pool_name="primary",pid="3000"} 400'
    ], metrics_lines
  end

  def test_metrics_expiration
    data = {
      "pid" => "1000",
      "hostname" => "localhost",
      "connections" => 50,
      "busy" => 20,
      "dead" => 10,
      "idle" => 20,
      "waiting" => 0,
      "size" => 120,
      "metric_labels" => {
        "pool_name" => "primary"
      }
    }

    stub_monotonic_clock(0) do
      collector.collect(data)
      collector.collect(data.merge("pid" => "1001", "hostname" => "localhost2"))
      assert_equal 6, collector.metrics.size
    end

    stub_monotonic_clock(max_metric_age + 1) do
      assert_equal 0, collector.metrics.size
    end
  end
end
