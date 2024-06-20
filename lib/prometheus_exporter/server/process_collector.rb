# frozen_string_literal: true

module PrometheusExporter::Server

  class ProcessCollector < TypeCollector
    MAX_METRIC_AGE = 60

    PROCESS_GAUGES = {
      heap_free_slots: "Free ruby heap slots.",
      heap_live_slots: "Used ruby heap slots.",
      v8_heap_size: "Total JavaScript V8 heap size (bytes).",
      v8_used_heap_size: "Total used JavaScript V8 heap size (bytes).",
      v8_physical_size: "Physical size consumed by V8 heaps.",
      v8_heap_count: "Number of V8 contexts running.",
      rss: "Total RSS used by process.",
      malloc_increase_bytes_limit: 'Limit before Ruby triggers a GC against current objects (bytes).',
      oldmalloc_increase_bytes_limit: 'Limit before Ruby triggers a major GC against old objects (bytes).'
    }

    PROCESS_COUNTERS = {
      major_gc_ops_total: "Major GC operations by process.",
      minor_gc_ops_total: "Minor GC operations by process.",
      allocated_objects_total: "Total number of allocated objects by process.",
    }

    def initialize
      @process_metrics = MetricsContainer.new(ttl: MAX_METRIC_AGE)
      @process_metrics.filter = -> (new_metric, old_metric) do
        new_metric["pid"] == old_metric["pid"] && new_metric["hostname"] == old_metric["hostname"]
      end
      @counter_metrics = {}
      PROCESS_COUNTERS.each do |k, help|
        k = k.to_s
        @counter_metrics[k] = PrometheusExporter::Metric::Counter.new(k, help)
      end
    end

    def type
      "process"
    end

    def metrics
      return [] if @process_metrics.length == 0

      metrics = {}

      @process_metrics.map do |m|
        metric_key = (m["metric_labels"] || {}).merge("pid" => m["pid"], "hostname" => m["hostname"])
        metric_key.merge!(m["custom_labels"]) if m["custom_labels"]

        PROCESS_GAUGES.each do |k, help|
          k = k.to_s
          if v = m[k]
            g = metrics[k] ||= PrometheusExporter::Metric::Gauge.new(k, help)
            g.observe(v, metric_key)
          end
        end

        PROCESS_COUNTERS.each do |k, help|
          k = k.to_s
          if v = m[k]
            c = metrics[k] ||= @counter_metrics[k]
            c.observe(v, metric_key)
          end
        end
      end

      metrics.values
    end

    def collect(obj)
      @process_metrics << obj
    end
  end
end
