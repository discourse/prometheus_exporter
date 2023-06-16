# frozen_string_literal: true

require_relative '../test_helper'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusSidekiqStatsCollectorTest < Minitest::Test
  include CollectorHelper

  def collector
    @collector ||= PrometheusExporter::Server::SidekiqStatsCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      'stats' => {
        'dead_size' => 1,
        'enqueued' => 2,
        'failed' => 3,
        'processed' => 4,
        'processes_size' => 5,
        'retry_size' => 6,
        'scheduled_size' => 7,
        'workers_size' => 8,
      }
    )

    metrics = collector.metrics
    expected = [
      "sidekiq_stats_dead_size 1",
      "sidekiq_stats_enqueued 2",
      "sidekiq_stats_failed 3",
      "sidekiq_stats_processed 4",
      "sidekiq_stats_processes_size 5",
      "sidekiq_stats_retry_size 6",
      "sidekiq_stats_scheduled_size 7",
      "sidekiq_stats_workers_size 8"
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end

  def test_only_fresh_metrics_are_collected
    stub_monotonic_clock(1.0) do
      collector.collect(
        'stats' => {
          'dead_size' => 1,
          'enqueued' => 2,
          'failed' => 3,
          'processed' => 4,
          'processes_size' => 5,
          'retry_size' => 6,
          'scheduled_size' => 7,
          'workers_size' => 8,
        }
      )
    end

    stub_monotonic_clock(2.0, advance: max_metric_age) do
      collector.collect(
        'stats' => {
          'dead_size' => 2,
          'enqueued' => 3,
          'failed' => 4,
          'processed' => 5,
          'processes_size' => 6,
          'retry_size' => 7,
          'scheduled_size' => 8,
          'workers_size' => 9,
        }
      )

      metrics = collector.metrics
      expected = [
        "sidekiq_stats_dead_size 2",
        "sidekiq_stats_enqueued 3",
        "sidekiq_stats_failed 4",
        "sidekiq_stats_processed 5",
        "sidekiq_stats_processes_size 6",
        "sidekiq_stats_retry_size 7",
        "sidekiq_stats_scheduled_size 8",
        "sidekiq_stats_workers_size 9"
      ]

      assert_equal expected, metrics.map(&:metric_text)
      assert_equal 1, collector.sidekiq_metrics.size
    end
  end
end
