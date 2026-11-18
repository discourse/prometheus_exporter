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

  def test_collecting_metrics_with_custom_labels
    collector.collect(
      "custom_labels" => {
        "service" => "payments",
        "env" => "prod",
      },
      "process" => {
        "busy" => 3,
        "concurrency" => 10,
        "labels" => {
          "labels" => "lab_a",
          "queues" => "critical,default",
          "quiet" => "false",
          "tag" => "main",
          "hostname" => "sidekiq-host",
          "identity" => "sidekiq-host:1",
        },
      },
    )

    metrics = collector.metrics
    expected = [
      'sidekiq_process_busy{service="payments",env="prod",labels="lab_a",queues="critical,default",quiet="false",tag="main",hostname="sidekiq-host",identity="sidekiq-host:1"} 3',
      'sidekiq_process_concurrency{service="payments",env="prod",labels="lab_a",queues="critical,default",quiet="false",tag="main",hostname="sidekiq-host",identity="sidekiq-host:1"} 10',
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end

  def test_custom_labels_overridden_by_process_labels
    collector.collect(
      "custom_labels" => {
        "service" => "billing",
        "tag" => "override",
      },
      "process" => {
        "busy" => 4,
        "concurrency" => 8,
        "labels" => {
          "labels" => "lab_x",
          "queues" => "default",
          "quiet" => "true",
          "tag" => "real_tag",
          "hostname" => "host-1",
          "identity" => "host-1:2",
        },
      },
    )

    # tag should be from process labels (real_tag) not custom_labels (override)
    metrics = collector.metrics
    expected = [
      'sidekiq_process_busy{service="billing",tag="real_tag",labels="lab_x",queues="default",quiet="true",hostname="host-1",identity="host-1:2"} 4',
      'sidekiq_process_concurrency{service="billing",tag="real_tag",labels="lab_x",queues="default",quiet="true",hostname="host-1",identity="host-1:2"} 8',
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end
end
