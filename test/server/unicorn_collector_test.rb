# frozen_string_literal: true

require 'test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusUnicornCollectorTest < Minitest::Test

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
  end

  def collector
    @collector ||= PrometheusExporter::Server::UnicornCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      'workers' => 4,
      'active_workers' => 3,
      'request_backlog' => 0
    )

    metrics = collector.metrics

    expected = [
      'unicorn_workers 4',
      'unicorn_active_workers 3',
      'unicorn_request_backlog 0'
    ]
    assert_equal expected, metrics.map(&:metric_text)
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
end
