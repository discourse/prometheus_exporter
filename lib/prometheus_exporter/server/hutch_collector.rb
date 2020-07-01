# frozen_string_literal: true

module PrometheusExporter::Server
  class HutchCollector < TypeCollector
    def initialize
      @hutch_jobs_total = nil
      @hutch_job_duration_seconds = nil
      @hutch_jobs_total = nil
      @hutch_failed_jobs_total = nil
    end

    def type
      "hutch"
    end

    def collect(obj)
      default_labels = { job_name: obj['name'] }
      custom_labels = obj['custom_labels']
      labels = custom_labels.nil? ? default_labels : default_labels.merge(custom_labels)

      ensure_hutch_metrics
      @hutch_job_duration_seconds.observe(obj["duration"], labels)
      @hutch_jobs_total.observe(1, labels)
      @hutch_failed_jobs_total.observe(1, labels) if !obj["success"]
    end

    def metrics
      if @hutch_jobs_total
        [@hutch_job_duration_seconds, @hutch_jobs_total, @hutch_failed_jobs_total]
      else
        []
      end
    end

    protected

    def ensure_hutch_metrics
      if !@hutch_jobs_total

        @hutch_job_duration_seconds = PrometheusExporter::Metric::Counter.new(
          "hutch_job_duration_seconds", "Total time spent in hutch jobs.")

        @hutch_jobs_total = PrometheusExporter::Metric::Counter.new(
          "hutch_jobs_total", "Total number of hutch jobs executed.")

        @hutch_failed_jobs_total = PrometheusExporter::Metric::Counter.new(
          "hutch_failed_jobs_total", "Total number failed hutch jobs executed.")
      end
    end
  end
end
