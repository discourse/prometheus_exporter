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
      @buffer = []
      @mutex = Mutex.new
    end

    def process(str)
      obj = JSON.parse(str)
      @mutex.synchronize do
        if obj["type"] == "web"
          observe_web(obj)
        elsif obj["type"] == "process"
          observe_process(obj)
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
        val = @metrics.values.map(&:to_prometheus_text).join("\n")

        metrics = {}

        if @process_metrics.length > 0
          val << "\n"

          @process_metrics.map do |m|
            metric_key = { pid: m["pid"], type: m["process_type"] }

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

          val << metrics.values.map(&:to_prometheus_text).join("\n")
        end

        val
      end
    end

    protected

    def register_metric(metric)
      @mutex.synchronize do
        @metrics << metric
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

    def observe_process(obj)
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      obj["created_at"] = now

      @process_metrics.delete_if do |current|
        obj["pid"] == current["pid"] || (current["created_at"] + MAX_PROCESS_METRIC_AGE < now)
      end
      @process_metrics << obj
    end

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
