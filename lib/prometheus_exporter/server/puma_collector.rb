module PrometheusExporter::Server
  class PumaCollector < TypeCollector
    PUMA_GAUGES = {
      workers: "Number of puma workers.",
      booted_workers: "Number of puma workers booted.",
      running: "Number of puma threads currently running.",
      backlog: "Number of requests waiting to be processed by a puma thread.",
      pool_capacity: "Number of puma threads available at current scale.",
      max_threads: "Number of puma threads at available at max scale.",
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
          labels.merge(phase: m["phase"])
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
      @puma_metrics << obj
    end
  end
end
