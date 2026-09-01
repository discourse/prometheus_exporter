# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/server"
require "prometheus_exporter/instrumentation"

class PrometheusGoodJobCollectorTest < Minitest::Test
  include CollectorHelper

  def collector
    @collector ||= PrometheusExporter::Server::GoodJobCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      {
        "scheduled" => 3,
        "retried" => 4,
        "queued" => 0,
        "running" => 5,
        "finished" => 100,
        "succeeded" => 2000,
        "discarded" => 9,
        "oldest_queued_age_seconds" => 42,
        "processes" => 2,
      },
    )

    metrics = collector.metrics

    expected = [
      "good_job_scheduled 3",
      "good_job_retried 4",
      "good_job_queued 0",
      "good_job_running 5",
      "good_job_finished 100",
      "good_job_succeeded 2000",
      "good_job_discarded 9",
      "good_job_oldest_queued_age_seconds 42",
      "good_job_processes 2",
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end

  def test_collecting_per_queue_metrics
    collector.collect(
      "type" => "good_job",
      "queued" => 5,
      "oldest_queued_age_seconds" => 30,
      "custom_labels" => {
        "queue" => "default",
      },
    )
    collector.collect(
      "type" => "good_job",
      "queued" => 2,
      "oldest_queued_age_seconds" => 7,
      "custom_labels" => {
        "queue" => "mailers",
      },
    )

    lines = collector.metrics.flat_map { |metric| metric.metric_text.split("\n") }

    assert_includes lines, 'good_job_queued{queue="default"} 5'
    assert_includes lines, 'good_job_queued{queue="mailers"} 2'
    assert_includes lines, 'good_job_oldest_queued_age_seconds{queue="default"} 30'
  end

  def test_collecting_metrics_with_custom_labels
    collector.collect(
      "type" => "good_job",
      "scheduled" => 3,
      "retried" => 4,
      "queued" => 0,
      "running" => 5,
      "finished" => 100,
      "succeeded" => 2000,
      "discarded" => 9,
      "custom_labels" => {
        "hostname" => "good_job_host",
      },
    )

    metrics = collector.metrics

    assert(metrics.first.metric_text.include?('good_job_scheduled{hostname="good_job_host"}'))
  end

  def test_metrics_expiration
    data = { "type" => "good_job", "scheduled" => 3, "retried" => 4, "queued" => 0 }

    stub_monotonic_clock(0) do
      collector.collect(data)
      assert_equal 3, collector.metrics.size
    end

    stub_monotonic_clock(max_metric_age + 1) { assert_equal 0, collector.metrics.size }
  end
end
