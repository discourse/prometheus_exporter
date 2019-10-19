# frozen_string_literal: true

module PrometheusExporter::Server

  class ProcessCollector < TypeCollector
    MAX_PROCESS_METRIC_AGE = 60
    PROCESS_GAUGES = {
      heap_free_slots: "Free ruby heap slots.",
      heap_live_slots: "Used ruby heap slots.",
      v8_heap_size: "Total JavaScript V8 heap size (bytes).",
      v8_used_heap_size: "Total used JavaScript V8 heap size (bytes).",
      v8_physical_size: "Physical size consumed by V8 heaps.",
      v8_heap_count: "Number of V8 contexts running.",
      rss: "Total RSS used by process.",
    }

    PROCESS_COUNTERS = {
      major_gc_ops_total: "Major GC operations by process.",
      minor_gc_ops_total: "Minor GC operations by process.",
      allocated_objects_total: "Total number of allocated objects by process.",
    }

    def initialize
      @process_metrics = []
    end

    def type
      "process"
    end

    def metrics
      return [] if @process_metrics.length == 0

      metrics = {}

      @process_metrics.map do |m|
        metric_key = m["metric_labels"].merge("pid" => m["pid"])
        metric_key.merge!(m["custom_labels"] || {})

        PROCESS_GAUGES.map do |k, help|
          k = k.to_s
          if v = m[k]
            g = metrics[k] ||= PrometheusExporter::Metric::Gauge.new(k, help)
            g.observe(v, metric_key)
          end
        end

        PROCESS_COUNTERS.map do |k, help|
          k = k.to_s
          if v = m[k]
            c = metrics[k] ||= PrometheusExporter::Metric::Counter.new(k, help)
            c.observe(v, metric_key)
          end
        end
      end

      metrics.values
    end

    def collect(obj)
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      obj["created_at"] = now

      @process_metrics.delete_if do |current|
        (obj["pid"] == current["pid"] && obj["hostname"] == current["hostname"]) ||
          (current["created_at"] + MAX_PROCESS_METRIC_AGE < now)
      end

      @process_metrics << obj
    end
  end
end
