# frozen_string_literal: true

require_relative '../test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class ProcessCollectorTest < Minitest::Test
  include CollectorHelper

  def collector
    @collector ||= PrometheusExporter::Server::ProcessCollector.new
  end

  def base_data
    {
      "type" => "process",
      "pid" => "1000",
      "hostname" => "localhost",
      "heap_free_slots" => 1000,
      "heap_live_slots" => 1001,
      "v8_heap_size" => 2000,
      "v8_used_heap_size" => 2001,
      "v8_physical_size" => 2003,
      "v8_heap_count" => 2004,
      "rss" => 3000,
      "major_gc_ops_total" => 4000,
      "minor_gc_ops_total" => 4001,
      "allocated_objects_total" => 4002,
      "marking_time" => 4003,
      "sweeping_time" => 4004,
    }
  end

  def test_metrics_collection
    collector.collect(base_data)

    assert_equal 12, collector.metrics.size
    assert_equal [
      'heap_free_slots{pid="1000",hostname="localhost"} 1000',
      'heap_live_slots{pid="1000",hostname="localhost"} 1001',
      'v8_heap_size{pid="1000",hostname="localhost"} 2000',
      'v8_used_heap_size{pid="1000",hostname="localhost"} 2001',
      'v8_physical_size{pid="1000",hostname="localhost"} 2003',
      'v8_heap_count{pid="1000",hostname="localhost"} 2004',
      'rss{pid="1000",hostname="localhost"} 3000',
      'marking_time{pid="1000",hostname="localhost"} 4003',
      'sweeping_time{pid="1000",hostname="localhost"} 4004',
      'major_gc_ops_total{pid="1000",hostname="localhost"} 4000',
      'minor_gc_ops_total{pid="1000",hostname="localhost"} 4001',
      'allocated_objects_total{pid="1000",hostname="localhost"} 4002',
    ], collector_metric_lines
  end

  def test_metrics_deduplication
    collector.collect(base_data)
    assert_equal 12, collector.metrics.size
    assert_equal 12, collector_metric_lines.size

    collector.collect(base_data)
    assert_equal 12, collector.metrics.size
    assert_equal 12, collector_metric_lines.size

    collector.collect(base_data.merge({ "hostname" => "localhost2" }))
    assert_equal 12, collector.metrics.size
    assert_equal 24, collector_metric_lines.size
  end

  def test_metrics_expiration
    stub_monotonic_clock(0) do
      collector.collect(base_data)
      assert_equal 12, collector.metrics.size
    end

    stub_monotonic_clock(max_metric_age + 1) do
      assert_equal 0, collector.metrics.size
    end
  end
end
