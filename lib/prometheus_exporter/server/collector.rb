# frozen_string_literal: true

module PrometheusExporter::Server

  class Collector < CollectorBase
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

    def initialize(json_serializer: nil)
      @process_metrics = []
      @metrics = {}
      @mutex = Mutex.new
      @collectors = {}
      @json_serializer = PrometheusExporter.detect_json_serializer(json_serializer)
      register_collector(WebCollector.new)
      register_collector(ProcessCollector.new)
      register_collector(SidekiqCollector.new)
      register_collector(DelayedJobCollector.new)
      register_collector(PumaCollector.new)
      register_collector(HutchCollector.new)
    end

    def register_collector(collector)
      @collectors[collector.type] = collector
    end

    def process(str)
      obj = @json_serializer.parse(str)
      @mutex.synchronize do
        if collector = @collectors[obj["type"]]
          collector.collect(obj)
        else
          metric = @metrics[obj["name"]]
          if !metric
            metric = register_metric_unsafe(obj)
          end

          keys = obj["keys"] || {}
          if obj["custom_labels"]
            keys = obj["custom_labels"].merge(keys)
          end

          case obj["prometheus_exporter_action"]
          when 'increment'
            metric.increment(keys, obj["value"])
          when 'decrement'
            metric.decrement(keys, obj["value"])
          else
            metric.observe(obj["value"], keys)
          end
        end
      end
    end

    def prometheus_metrics_text
      @mutex.synchronize do
        (@metrics.values + @collectors.values.map(&:metrics).flatten)
          .map(&:to_prometheus_text).join("\n")
      end
    end

    def register_metric(metric)
      @mutex.synchronize do
        @metrics[metric.name] = metric
      end
    end

    protected

    def register_metric_unsafe(obj)
      name = obj["name"]
      help = obj["help"]

      metric =
        case obj["type"]
        when "gauge"
          PrometheusExporter::Metric::Gauge.new(name, help)
        when "counter"
          PrometheusExporter::Metric::Counter.new(name, help)
        when "summary"
          PrometheusExporter::Metric::Summary.new(name, help)
        when "histogram"
          PrometheusExporter::Metric::Histogram.new(name, help)
        end

      if metric
        @metrics[name] = metric
      else
        STDERR.puts "failed to register metric #{obj}"
      end
    end
  end
end
