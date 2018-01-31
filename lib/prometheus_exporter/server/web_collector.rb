# frozen_string_literal: true

module PrometheusExporter::Server
  class WebCollector < TypeCollector
    def initialize
      @metrics = {}
    end

    def type
      "web"
    end

    def collect(obj)
      ensure_metrics
      observe(obj)
    end

    def metrics
      @metrics.values
    end

    protected

    def ensure_metrics
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

    def observe(obj)

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
  end
end
