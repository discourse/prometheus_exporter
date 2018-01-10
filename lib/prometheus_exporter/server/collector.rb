# frozen_string_literal: true

module PrometheusExporter::Server

  class Collector

    def initialize
      @metrics = {}
      @buffer = []
      @mutex = Mutex.new
    end

    def process(obj)
      @mutex.synchronize do
        metric = @metrics[obj["name"]]
        if !metric
          metric = register_metric_unsafe(obj)
        end
        metric.observe(obj["value"], obj["keys"])
      end
    end

    def prometheus_metrics_text
      @mutex.synchronize do
        @metrics.values.map(&:to_prometheus_text).join("\n")
      end
    end

    def register_metric(metric)
      @mutex.synchronize do
        @metrics << metric
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
