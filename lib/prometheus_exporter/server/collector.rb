# frozen_string_literal: true

module PrometheusExporter::Server

  class Collector < CollectorBase
    MAX_PROCESS_METRIC_AGE = 60
    PROCESS_GAUGES = {
      heap_free_slots: "Free ruby heap slots",
      heap_live_slots: "Used ruby heap slots",
      v8_heap_size: "Total JavaScript V8 heap size (bytes)",
      v8_used_heap_size: "Total used JavaScript V8 heap size (bytes)",
      v8_physical_size: "Physical size consumed by V8 heaps",
      v8_heap_count: "Number of V8 contexts running",
      rss: "Total RSS used by process",
    }

    PROCESS_COUNTERS = {
      major_gc_count: "Major GC operations by process",
      minor_gc_count: "Minor GC operations by process",
      total_allocated_objects: "Total number of allocateds objects by process",
    }

    def initialize
      @process_metrics = []
      @metrics = {}
      @mutex = Mutex.new
      @collectors = {}
      register_collector(WebCollector.new)
      register_collector(ProcessCollector.new)
      register_collector(SidekiqCollector.new)
    end

    def register_collector(collector)
      @collectors[collector.type] = collector
    end

    def process(str)
      obj = JSON.parse(str)
      @mutex.synchronize do
        if collector = @collectors[obj["type"]]
          collector.observe(obj)
        else
          metric = @metrics[obj["name"]]
          if !metric
            metric = register_metric_unsafe(obj)
          end
          metric.observe(obj["value"], obj["keys"])
        end
      end
    end

    def prometheus_metrics_text
      @mutex.synchronize do
        (@metrics.values + @collectors.values.map(&:metrics).flatten)
          .map(&:to_prometheus_text).join("\n")
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
        end

      if metric
        @metrics[name] = metric
      else
        STDERR.puts "failed to register metric #{obj}"
      end
    end
  end
end
