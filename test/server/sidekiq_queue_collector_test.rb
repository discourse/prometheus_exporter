# frozen_string_literal: true

require 'test_helper'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusSidekiqQueueCollectorTest < Minitest::Test
  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
  end

  def collector
    @collector ||= PrometheusExporter::Server::SidekiqQueueCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      'queues' => [
        'backlog' => 16,
        'latency_seconds' => 7,
        'labels' => { 'queue' => 'default' }
      ]
    )

    metrics = collector.metrics

    expected = [
      'sidekiq_queue_backlog{queue="default"} 16',
      'sidekiq_queue_latency_seconds{queue="default"} 7',
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end

  def test_collecting_metrics_with_client_default_labels
    collector.collect(
      'queues' => [
        'backlog' => 16,
        'latency_seconds' => 7,
        'labels' => { 'queue' => 'default' }
      ],
      'custom_labels' => {
        'environment' => 'test'
      }
    )

    metrics = collector.metrics

    expected = [
      'sidekiq_queue_backlog{queue="default",environment="test"} 16',
      'sidekiq_queue_latency_seconds{queue="default",environment="test"} 7',
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end

  def test_only_fresh_metrics_are_collected
    Process.stub(:clock_gettime, 1.0) do
      collector.collect(
        'queues' => [
          'backlog' => 1,
          'labels' => { 'queue' => 'default' }
        ]
      )
    end

    Process.stub(:clock_gettime, 2.0 + PrometheusExporter::Server::SidekiqQueueCollector::MAX_SIDEKIQ_METRIC_AGE) do
      collector.collect(
        'queues' => [
          'latency_seconds' => 1,
          'labels' => { 'queue' => 'default' }
        ]
      )

      metrics = collector.metrics

      expected = [
        'sidekiq_queue_latency_seconds{queue="default"} 1',
      ]
      assert_equal expected, metrics.map(&:metric_text)
    end
  end
end
