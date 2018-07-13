require 'test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusWebCollectorTest < Minitest::Test
  def collector
    @collector ||= PrometheusExporter::Server::WebCollector.new
  end

  def test_collecting_metrics_without_specific_timings
    collector.collect({
      type: "web",
      timings: nil,
      action: 'index',
      controller: 'home',
      status: 200
    })

    metrics = collector.metrics

    assert_equal 5, metrics.size
  end

  def test_collecting_metrics
    collector.collect({
      "type" => "web",
      "timings" => {
        "sql" => {
          duration: 0.5,
          count: 40
        },
        "redis" => {
          duration: 0.03,
          count: 4
        },
        "queue" => 0.03,
        "total_duration" => 1.0
      },
      "action" => 'index',
      "controller" => 'home',
      "status" => 200
    })

    metrics = collector.metrics
    assert_equal 5, metrics.size
  end

  def test_collecting_metrics_with_custom_labels
    collector.collect({
      'type' => 'web',
      'timings' => nil,
      'action' => 'index',
      'controller' => 'home',
      'status' => 200,
      'custom_labels' => {
        'service' => 'service1'
      }
    })

    metrics = collector.metrics

    assert_equal 5, metrics.size
    assert(metrics.first.metric_text.include?('http_requests_total{controller="home",action="index",service="service1",status="200"}'))
  end
end
