# frozen_string_literal: true

module PrometheusExporter::Server
  class PumaCollector < TypeCollector
    MAX_PUMA_METRIC_AGE = 30
    PUMA_GAUGES = {
      workers_total: "Number of puma workers.",
      booted_workers_total: "Number of puma workers booted.",
      old_workers_total: "Number of old puma workers.",
      running_threads_total: "Number of puma threads currently running.",
      request_backlog_total: "Number of requests waiting to be processed by a puma thread.",
      thread_pool_capacity_total: "Number of puma threads available at current scale.",
      max_threads_total: "Number of puma threads at available at max scale.",
    }

    def initialize
      @puma_metrics = []
    end

    def type
      "puma"
    end

    def metrics
      return [] if @puma_metrics.length == 0

      metrics = {}

      @puma_metrics.map do |m|
        labels = {}
        if m["phase"]
          labels.merge!(phase: m["phase"])
        end
        if m["custom_labels"]
          labels.merge!(m["custom_labels"])
        end

        PUMA_GAUGES.map do |k, help|
          k = k.to_s
          if v = m[k]
            g = metrics[k] ||= PrometheusExporter::Metric::Gauge.new("puma_#{k}", help)
            g.observe(v, labels)
          end
        end
      end

      metrics.values
    end

    def collect(obj)
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      obj["created_at"] = now
      @puma_metrics.delete_if { |m| m["created_at"] + MAX_PUMA_METRIC_AGE < now }
      @puma_metrics << obj
    end
  end
end
