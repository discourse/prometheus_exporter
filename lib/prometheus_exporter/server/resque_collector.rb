# frozen_string_literal: true

module PrometheusExporter::Server
  class ResqueCollector < TypeCollector
    MAX_RESQUE_METRIC_AGE = 30
    RESQUE_GAUGES = {
      processed_jobs: "Total number of processed Resque jobs.",
      failed_jobs: "Total number of failed Resque jobs.",
      pending_jobs: "Total number of pending Resque jobs.",
      queues: "Total number of Resque queues.",
      workers: "Total number of Resque workers running.",
      working: "Total number of Resque workers working."
    }

    def initialize
      @resque_metrics = []
      @gauges = {}
    end

    def type
      "resque"
    end

    def metrics
      return [] if resque_metrics.length == 0

      resque_metrics.map do |metric|
        labels = metric.fetch("custom_labels", {})

        RESQUE_GAUGES.map do |name, help|
          name = name.to_s
          if value = metric[name]
            gauge = gauges[name] ||= PrometheusExporter::Metric::Gauge.new("resque_#{name}", help)
            gauge.observe(value, labels)
          end
        end
      end

      gauges.values
    end

    def collect(object)
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      object["created_at"] = now
      resque_metrics.delete_if { |metric| metric["created_at"] + MAX_RESQUE_METRIC_AGE < now }
      resque_metrics << object
    end

    private

    attr_reader :resque_metrics, :gauges
  end
end
