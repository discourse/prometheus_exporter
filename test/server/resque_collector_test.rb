# frozen_string_literal: true

require 'test_helper'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusResqueCollectorTest < Minitest::Test

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
  end

  def collector
    @collector ||= PrometheusExporter::Server::ResqueCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      'pending_jobs_total' => 4,
      'processed_jobs_total' => 7,
      'failed_jobs_total' => 1
    )

    metrics = collector.metrics

    expected = [
      'resque_processed_jobs_total 7',
      'resque_failed_jobs_total 1',
      'resque_pending_jobs_total 4'
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end

  def test_collecting_metrics_with_custom_labels
    collector.collect(
      'type' => 'resque',
      'pending_jobs_total' => 1,
      'processed_jobs_total' => 2,
      'failed_jobs_total' => 3,
      'custom_labels' => {
        'hostname' => 'a323d2f681e2'
      }
    )

    metrics = collector.metrics

    assert(metrics.first.metric_text.include?('resque_processed_jobs_total{hostname="a323d2f681e2"}'))
  end
end
