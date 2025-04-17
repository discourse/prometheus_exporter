# frozen_string_literal: true

module PrometheusExporter::Server
  class PumaCollector < TypeCollector
    MAX_PUMA_METRIC_AGE = 30
    PUMA_GAUGES = {
      workers: "Number of puma workers.",
      booted_workers: "Number of puma workers booted.",
      old_workers: "Number of old puma workers.",
      running_threads: "Number of puma threads currently running.",
      request_backlog: "Number of requests waiting to be processed by a puma thread.",
      thread_pool_capacity: "Number of puma threads available at current scale.",
      max_threads: "Number of puma threads at available at max scale.",
      busy_threads: "Wholistic stat reflecting the overall current state of work to be done and the capacity to do it",
    }

    def initialize
      @puma_metrics = MetricsContainer.new(ttl: MAX_PUMA_METRIC_AGE)
      @puma_metrics.filter = ->(new_metric, old_metric) do
        new_metric["pid"] == old_metric["pid"] && new_metric["hostname"] == old_metric["hostname"]
      end
    end

    def type
      "puma"
    end

    def metrics
      return [] if @puma_metrics.length == 0

      metrics = {}

      @puma_metrics.map do |m|
        labels = {}
        labels.merge!(phase: m["phase"]) if m["phase"]
        labels.merge!(m["custom_labels"]) if m["custom_labels"]
        labels.merge!(m["metric_labels"]) if m["metric_labels"]

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
      @puma_metrics << obj
    end
  end
end
