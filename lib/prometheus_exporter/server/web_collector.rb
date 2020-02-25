# frozen_string_literal: true

require 'yaml'

module PrometheusExporter::Server
  class WebCollector < TypeCollector
    def initialize
      if ENV["RAIL_PROMETHEUS_EXPORTER_CONFIG"] then
        @config = YAML.load(File.read(ENV["RAIL_PROMETHEUS_EXPORTER_CONFIG"]))
      else
        puts("Could not find env RAIL_PROMETHEUS_EXPORTER_CONFIG. Loading defualt configuration.")
        @config = {"histogram_buckets"=>[ 0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0, 20.0, 30.0 ]}
      end
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
      unless @http_requests_total
        @metrics["http_requests_total"] = @http_requests_total = PrometheusExporter::Metric::Counter.new(
          "http_requests_total",
          "Total HTTP requests from web app."
        )

        # Commenting out request duration summary metrics
        # @metrics["http_duration_seconds"] = @http_duration_seconds = PrometheusExporter::Metric::Summary.new(
        #   "http_duration_seconds",
        #   "Time spent in HTTP reqs in seconds."
        # )

        @metrics["http_duration_seconds"] = @http_duration_seconds = PrometheusExporter::Metric::Histogram.new(
          "http_duration_seconds",
          "Time spent in HTTP reqs in seconds.",
          opts={:buckets=>@config["histogram_buckets"]}
        )

        @metrics["http_redis_duration_seconds"] = @http_redis_duration_seconds = PrometheusExporter::Metric::Summary.new(
          "http_redis_duration_seconds",
          "Time spent in HTTP reqs in Redis, in seconds."
        )

        @metrics["http_sql_duration_seconds"] = @http_sql_duration_seconds = PrometheusExporter::Metric::Summary.new(
          "http_sql_duration_seconds",
          "Time spent in HTTP reqs in SQL in seconds."
        )

        @metrics["http_queue_duration_seconds"] = @http_queue_duration_seconds = PrometheusExporter::Metric::Summary.new(
          "http_queue_duration_seconds",
          "Time spent queueing the request in load balancer in seconds."
        )
      end
    end

    def observe(obj)
      default_labels = {
        controller: obj['controller'] || 'other',
        action: obj['action'] || 'other'
      }
      custom_labels = obj['custom_labels']
      labels = custom_labels.nil? ? default_labels : default_labels.merge(custom_labels)

      @http_requests_total.observe(1, labels.merge(status: obj["status"]))

      if timings = obj["timings"]
        @http_duration_seconds.observe(timings["total_duration"], labels)
        if redis = timings["redis"]
          @http_redis_duration_seconds.observe(redis["duration"], labels)
        end
        if sql = timings["sql"]
          @http_sql_duration_seconds.observe(sql["duration"], labels)
        end
      end
      if queue_time = obj["queue_time"]
        @http_queue_duration_seconds.observe(queue_time, labels)
      end
    end
  end
end
