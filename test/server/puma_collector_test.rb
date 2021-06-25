# frozen_string_literal: true

require 'test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusPumaCollectorTest < Minitest::Test

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
  end

  def collector
    @collector ||= PrometheusExporter::Server::PumaCollector.new
  end

  def test_collecting_metrics_for_different_hosts_without_custom_labels
    collector.collect(
      "type" => "puma",
      "pid" => "1000",
      "hostname" => "test1.example.com",
      "phase" => 0,
      "workers_total" => 2,
      "booted_workers_total" => 2,
      "old_workers_total" => 0,
      "request_backlog_total" => 0,
      "running_threads_total" => 4,
      "thread_pool_capacity_total" => 10,
      "max_threads_total" => 10
    )

    collector.collect(
      "type" => "puma",
      "pid" => "1000",
      "hostname" => "test2.example.com",
      "phase" => 0,
      "workers_total" => 4,
      "booted_workers_total" => 4,
      "old_workers_total" => 0,
      "request_backlog_total" => 1,
      "running_threads_total" => 9,
      "thread_pool_capacity_total" => 10,
      "max_threads_total" => 10
    )

    # overwriting previous metrics from first host
    collector.collect(
      "type" => "puma",
      "pid" => "1000",
      "hostname" => "test1.example.com",
      "phase" => 0,
      "workers_total" => 3,
      "booted_workers_total" => 3,
      "old_workers_total" => 0,
      "request_backlog_total" => 2,
      "running_threads_total" => 8,
      "thread_pool_capacity_total" => 10,
      "max_threads_total" => 10
    )

    metrics = collector.metrics
    assert_equal 7, metrics.size
    assert_equal "puma_workers_total{phase=\"0\"} 3",
                 metrics.first.metric_text
  end

  def test_collecting_metrics_for_different_hosts_with_custom_labels
    collector.collect(
      "type" => "puma",
      "pid" => "1000",
      "hostname" => "test1.example.com",
      "phase" => 0,
      "workers_total" => 2,
      "booted_workers_total" => 2,
      "old_workers_total" => 0,
      "request_backlog_total" => 0,
      "running_threads_total" => 4,
      "thread_pool_capacity_total" => 10,
      "max_threads_total" => 10,
      "custom_labels" => {
        "hostname" => "test1.example.com"
      }
    )

    collector.collect(
      "type" => "puma",
      "pid" => "1000",
      "hostname" => "test2.example.com",
      "phase" => 0,
      "workers_total" => 4,
      "booted_workers_total" => 4,
      "old_workers_total" => 0,
      "request_backlog_total" => 1,
      "running_threads_total" => 9,
      "thread_pool_capacity_total" => 10,
      "max_threads_total" => 10,
      "custom_labels" => {
        "hostname" => "test2.example.com"
      }
    )

    # overwriting previous metrics from first host
    collector.collect(
      "type" => "puma",
      "pid" => "1000",
      "hostname" => "test1.example.com",
      "phase" => 0,
      "workers_total" => 3,
      "booted_workers_total" => 3,
      "old_workers_total" => 0,
      "request_backlog_total" => 2,
      "running_threads_total" => 8,
      "thread_pool_capacity_total" => 10,
      "max_threads_total" => 10,
      "custom_labels" => {
        "hostname" => "test1.example.com"
      }
    )

    metrics = collector.metrics
    assert_equal 7, metrics.size
    assert_equal "puma_workers_total{phase=\"0\",hostname=\"test2.example.com\"} 4\n" \
                 "puma_workers_total{phase=\"0\",hostname=\"test1.example.com\"} 3",
                 metrics.first.metric_text
  end

end
