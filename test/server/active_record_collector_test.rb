# frozen_string_literal: true

require 'test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusActiveRecordCollectorTest < Minitest::Test
  def collector
    @collector ||= PrometheusExporter::Server::ActiveRecordCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      "type" => "active_record",
      "pid" => "1000",
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
      "connections" => 50,
      "busy" => 20,
      "dead" => 10,
      "idle" => 20,
      "waiting" => 0,
      "size" => 120,
      'metric_labels' => {
        'service' => 'service1'
      }
    )

    metrics = collector.metrics
    assert_equal 6, metrics.size
    assert(metrics.first.metric_text.include?('active_record_connection_pool_connections{service="service1",pid="1000"} 50'))
  end
end
