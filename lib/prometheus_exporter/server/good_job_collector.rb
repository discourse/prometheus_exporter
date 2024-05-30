# frozen_string_literal: true

module PrometheusExporter::Server
  class GoodJobCollector < TypeCollector
    MAX_METRIC_AGE = 30
    GOOD_JOB_GAUGES = {
      scheduled: "Total number of scheduled GoodJob jobs.",
      retried: "Total number of retried GoodJob jobs.",
      queued: "Total number of queued GoodJob jobs.",
      running: "Total number of running GoodJob jobs.",
      finished: "Total number of finished GoodJob jobs.",
      succeeded: "Total number of succeeded GoodJob jobs.",
      discarded: "Total number of discarded GoodJob jobs."
    }

    def initialize
      @good_job_metrics = MetricsContainer.new(ttl: MAX_METRIC_AGE)
      @gauges = {}
    end

    def type
      "good_job"
    end

    def metrics
      return [] if good_job_metrics.length.zero?

      good_job_metrics.each(&method(:process_metric))
      gauges.values
    end

    def collect(object)
      @good_job_metrics << object
    end

    private

    attr_reader :good_job_metrics, :gauges

    def process_metric(metric)
      labels = metric.fetch("custom_labels", {})

      GOOD_JOB_GAUGES.each do |name, help|
        next unless (value = metric[name.to_s])

        gauge = gauges[name] ||= PrometheusExporter::Metric::Gauge.new("good_job_#{name}", help)
        observe_metric(gauge, metric, labels, value)
      end
    end

    def observe_metric(gauge, metric, labels, value)
      if metric["by_queue"]
        value.each { |queue_name, count| gauge.observe(count, labels.merge(queue_name: queue_name)) }
      else
        gauge.observe(value, labels)
      end
    end
  end
end
