# frozen_string_literal: true

require_relative '../test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusUnicornCollectorTest < Minitest::Test
  include CollectorHelper

  def collector
    @collector ||= PrometheusExporter::Server::UnicornCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      'workers' => 4,
      'active_workers' => 3,
      'request_backlog' => 0
    )

    assert_collector_metric_lines [
      'unicorn_workers 4',
      'unicorn_active_workers 3',
      'unicorn_request_backlog 0'
    ]
  end

  def test_collecting_metrics_with_custom_labels
    collector.collect(
      'type' => 'unicorn',
      'workers' => 2,
      'active_workers' => 0,
      'request_backlog' => 0,
      'custom_labels' => {
        'hostname' => 'a323d2f681e2'
      }
    )

    metrics = collector.metrics

    assert(metrics.first.metric_text.include?('unicorn_workers{hostname="a323d2f681e2"}'))
  end

  def test_metrics_deduplication
    collector.collect('workers' => 4, 'active_workers' => 3, 'request_backlog' => 0)
    collector.collect('workers' => 4, 'active_workers' => 3, 'request_backlog' => 0)
    collector.collect('workers' => 4, 'active_workers' => 3, 'request_backlog' => 0, 'hostname' => 'localhost2')
    assert_equal 3, collector_metric_lines.size
  end

  def test_metrics_expiration
    stub_monotonic_clock(0) do
      collector.collect('workers' => 4, 'active_workers' => 3, 'request_backlog' => 0)
      assert_equal 3, collector.metrics.size
    end

    stub_monotonic_clock(max_metric_age + 1) do
      assert_equal 0, collector.metrics.size
    end
  end
end
