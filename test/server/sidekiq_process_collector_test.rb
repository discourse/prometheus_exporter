# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/server"
require "prometheus_exporter/instrumentation"

class PrometheusSidekiqProcessCollectorTest < Minitest::Test
  include CollectorHelper

  def collector
    @collector ||= PrometheusExporter::Server::SidekiqProcessCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      "process" => {
        "busy" => 1,
        "concurrency" => 2,
        "labels" => {
          "labels" => "lab_1,lab_2",
          "queues" => "default,reliable",
          "quiet" => "false",
          "tag" => "default",
          "hostname" => "sidekiq-1234",
          "identity" => "sidekiq-1234:1",
        },
      },
    )

    metrics = collector.metrics
    expected = [
      'sidekiq_process_busy{labels="lab_1,lab_2",queues="default,reliable",quiet="false",tag="default",hostname="sidekiq-1234",identity="sidekiq-1234:1"} 1',
      'sidekiq_process_concurrency{labels="lab_1,lab_2",queues="default,reliable",quiet="false",tag="default",hostname="sidekiq-1234",identity="sidekiq-1234:1"} 2',
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end

  def test_only_fresh_metrics_are_collected
    stub_monotonic_clock(1.0) do
      collector.collect(
        "process" => {
          "busy" => 1,
          "concurrency" => 2,
          "labels" => {
            "labels" => "lab_1,lab_2",
            "queues" => "default,reliable",
            "quiet" => "false",
            "tag" => "default",
            "hostname" => "sidekiq-1234",
            "identity" => "sidekiq-1234:1",
          },
        },
      )
    end

    stub_monotonic_clock(2.0, advance: max_metric_age) do
      collector.collect(
        "process" => {
          "busy" => 2,
          "concurrency" => 2,
          "labels" => {
            "labels" => "other_label",
            "queues" => "default,reliable",
            "quiet" => "true",
            "tag" => "default",
            "hostname" => "sidekiq-1234",
            "identity" => "sidekiq-1234:1",
          },
        },
      )

      metrics = collector.metrics
      expected = [
        'sidekiq_process_busy{labels="other_label",queues="default,reliable",quiet="true",tag="default",hostname="sidekiq-1234",identity="sidekiq-1234:1"} 2',
        'sidekiq_process_concurrency{labels="other_label",queues="default,reliable",quiet="true",tag="default",hostname="sidekiq-1234",identity="sidekiq-1234:1"} 2',
      ]
      assert_equal expected, metrics.map(&:metric_text)
    end
  end
end
