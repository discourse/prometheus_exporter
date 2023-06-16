# frozen_string_literal: true

require_relative '../test_helper'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusResqueCollectorTest < Minitest::Test
  include CollectorHelper

  def collector
    @collector ||= PrometheusExporter::Server::ResqueCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      'pending_jobs' => 4,
      'processed_jobs' => 7,
      'failed_jobs' => 1
    )

    metrics = collector.metrics

    expected = [
      'resque_processed_jobs 7',
      'resque_failed_jobs 1',
      'resque_pending_jobs 4'
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end

  def test_collecting_metrics_with_custom_labels
    collector.collect(
      'type' => 'resque',
      'pending_jobs' => 1,
      'processed_jobs' => 2,
      'failed_jobs' => 3,
      'custom_labels' => {
        'hostname' => 'a323d2f681e2'
      }
    )

    metrics = collector.metrics
    assert(metrics.first.metric_text.include?('resque_processed_jobs{hostname="a323d2f681e2"}'))
  end

  def test_metrics_expiration
    data = {
      'type' => 'resque',
      'pending_jobs' => 1,
      'processed_jobs' => 2,
      'failed_jobs' => 3
    }

    stub_monotonic_clock(0) do
      collector.collect(data)
      assert_equal 3, collector.metrics.size
    end

    stub_monotonic_clock(max_metric_age + 1) do
      assert_equal 0, collector.metrics.size
    end
  end
end
