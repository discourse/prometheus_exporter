# frozen_string_literal: true

module PrometheusExporter::Server

  class Collector < CollectorBase

    def initialize(json_serializer: nil)
      @process_metrics = []
      @metrics = {}
      @mutex = Mutex.new
      @collectors = {}
      @json_serializer = PrometheusExporter.detect_json_serializer(json_serializer)
      register_collector(WebCollector.new)
      register_collector(ProcessCollector.new)
      register_collector(SidekiqCollector.new)
      register_collector(SidekiqQueueCollector.new)
      register_collector(SidekiqProcessCollector.new)
      register_collector(SidekiqStatsCollector.new)
      register_collector(DelayedJobCollector.new)
      register_collector(PumaCollector.new)
      register_collector(HutchCollector.new)
      register_collector(UnicornCollector.new)
      register_collector(ActiveRecordCollector.new)
      register_collector(ShoryukenCollector.new)
      register_collector(ResqueCollector.new)
    end

    def register_collector(collector)
      @collectors[collector.type] = collector
    end

    def process(str)
      process_hash(@json_serializer.parse(str))
    end

    def process_hash(obj)
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
      opts = symbolize_keys(obj["opts"] || {})

      metric =
        case obj["type"]
        when "gauge"
          PrometheusExporter::Metric::Gauge.new(name, help)
        when "counter"
          PrometheusExporter::Metric::Counter.new(name, help)
        when "summary"
          PrometheusExporter::Metric::Summary.new(name, help, opts)
        when "histogram"
          PrometheusExporter::Metric::Histogram.new(name, help, opts)
        end

      if metric
        @metrics[name] = metric
      else
        STDERR.puts "failed to register metric #{obj}"
      end
    end

    def symbolize_keys(hash)
      hash.inject({}) { |memo, k| memo[k.first.to_sym] = k.last; memo }
    end
  end
end
