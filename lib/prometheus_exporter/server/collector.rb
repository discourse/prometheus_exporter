# frozen_string_literal: true

module PrometheusExporter::Server

  class Collector

    def initialize
      @metrics = {}
      @buffer = []
      @mutex = Mutex.new
    end

    def process(obj)
      metric = @metrics[obj["name"]]
      if !metric
        metric = register_metric(obj)
      end
      metric.observe(obj["value"], obj["keys"])
    end

    def prometheus_metrics_text
      @metrics.values.map(&:to_prometheus_text).join("\n")
    end

    protected

    def register_metric(obj)
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
