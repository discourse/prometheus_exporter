# frozen_string_literal: true

module PrometheusExporter::Server

  class Collector

    def initialize
      @metrics = {}
      @buffer = []
      @mutex = Mutex.new
    end

    def process(str)
      obj = JSON.parse(str)
      @mutex.synchronize do
        if obj["type"] == "web"
          observe_web(obj)
        else
          metric = @metrics[obj["name"]]
          if !metric
            metric = register_metric_unsafe(obj)
          end
          metric.observe(obj["value"], obj["keys"])
        end
      end
    end

    def ensure_web_metrics
      unless @http_requests
        @metrics["http_requests"] = @http_requests = PrometheusExporter::Metric::Counter.new(
          "http_requests",
          "Total HTTP requests from web app"
        )

        @metrics["http_duration_seconds"] = @http_duration_seconds = PrometheusExporter::Metric::Summary.new(
          "http_duration_seconds",
          "Time spent in HTTP reqs in seconds"
        )

        @metrics["http_redis_duration_seconds"] = @http_redis_duration_seconds = PrometheusExporter::Metric::Summary.new(
          "http_redis_duration_seconds",
          "Time spent in HTTP reqs in redis seconds"
        )

        @metrics["http_sql_duration_seconds"] = @http_sql_duration_seconds = PrometheusExporter::Metric::Summary.new(
          "http_sql_duration_seconds",
          "Time spent in HTTP reqs in SQL in seconds"
        )
      end
    end

    def observe_web(obj)
      ensure_web_metrics

      labels = {
        controller: obj["controller"] || "other",
        action: obj["action"] || "other"
      }

      @http_requests.observe(1, labels.merge(status: obj["status"]))

      if timings = obj["timings"]
        @http_duration_seconds.observe(timings["total_duration"], labels)
        if redis = timings["redis"]
          @http_redis_duration_seconds.observe(redis["duration"], labels)
        end
        if sql = timings["sql"]
          @http_sql_duration_seconds.observe(sql["duration"], labels)
        end
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
