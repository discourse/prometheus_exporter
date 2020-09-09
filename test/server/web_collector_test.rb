# frozen_string_literal: true

require 'test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusWebCollectorTest < Minitest::Test
  def collector
    @collector ||= PrometheusExporter::Server::WebCollector.new
  end

  def test_collecting_metrics_without_specific_timings
    collector.collect(
      type: "web",
      timings: nil,
      action: 'index',
      controller: 'home',
      status: 200
    )

    metrics = collector.metrics

    assert_equal 5, metrics.size
  end

  def test_collecting_metrics
    collector.collect(
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
      "status" => 200,
      "http_labels_on_duration" => false
    )

    metrics = collector.metrics
    assert_equal 5, metrics.size

    http_duration_seconds = metrics[1].metric_text
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",quantile="0.99"}'), "has duration quantile 0.99")
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",quantile="0.9"}'), "has duration quantile 0.9")
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",quantile="0.5"}'), "has duration quantile 0.5")
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",quantile="0.1"}'), "has duration quantile 0.1")
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",quantile="0.01"}'), "has duration quantile 0.01")
  end

  def test_collecting_metrics_with_http_labels_on_duration
    collector.collect(
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
      "status" => 200,
      "http_labels_on_duration" => true
    )

    metrics = collector.metrics
    assert_equal 5, metrics.size

    http_duration_seconds = metrics[1].metric_text
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",status="200",quantile="0.99"}'), "has duration quantile 0.99")
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",status="200",quantile="0.9"}'), "has duration quantile 0.9")
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",status="200",quantile="0.5"}'), "has duration quantile 0.5")
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",status="200",quantile="0.1"}'), "has duration quantile 0.1")
    assert(http_duration_seconds.include?('http_duration_seconds{controller="home",action="index",status="200",quantile="0.01"}'), "has duration quantile 0.01")
  end

  def test_collecting_metrics_with_custom_labels
    collector.collect(
      'type' => 'web',
      'timings' => nil,
      'action' => 'index',
      'controller' => 'home',
      'status' => 200,
      'custom_labels' => {
        'service' => 'service1'
      }
    )

    metrics = collector.metrics

    assert_equal 5, metrics.size
    assert(metrics.first.metric_text.include?('http_requests_total{controller="home",action="index",service="service1",status="200"}'))
  end
end
