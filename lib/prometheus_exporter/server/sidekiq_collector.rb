# frozen_string_literal: true

module PrometheusExporter::Server
  class SidekiqCollector < TypeCollector

    def initialize
      @sidekiq_jobs_total = nil
      @sidekiq_job_duration_seconds = nil
      @sidekiq_jobs_total = nil
      @sidekiq_restarted_jobs_total = nil
      @sidekiq_failed_jobs_total = nil
      @sidekiq_dead_jobs_total = nil
    end

    def type
      "sidekiq"
    end

    def collect(obj)
      default_labels = { job_name: obj['name'], queue: obj['queue'] }
      custom_labels = obj['custom_labels']
      labels = custom_labels.nil? ? default_labels : default_labels.merge(custom_labels)

      ensure_sidekiq_metrics
      if obj["dead"]
        @sidekiq_dead_jobs_total.observe(1, labels)
      else
        @sidekiq_job_duration_seconds.observe(obj["duration"], labels)
        @sidekiq_jobs_total.observe(1, labels)
        @sidekiq_restarted_jobs_total.observe(1, labels) if obj["shutdown"]
        @sidekiq_failed_jobs_total.observe(1, labels) if !obj["success"] && !obj["shutdown"]
      end
    end

    def metrics
      if @sidekiq_jobs_total
        [
          @sidekiq_job_duration_seconds,
          @sidekiq_jobs_total,
          @sidekiq_restarted_jobs_total,
          @sidekiq_failed_jobs_total,
          @sidekiq_dead_jobs_total,
        ]
      else
        []
      end
    end

    protected

    def ensure_sidekiq_metrics
      if !@sidekiq_jobs_total

        @sidekiq_job_duration_seconds =
        PrometheusExporter::Metric::Base.default_aggregation.new(
          "sidekiq_job_duration_seconds", "Total time spent in sidekiq jobs.")

        @sidekiq_jobs_total =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_jobs_total", "Total number of sidekiq jobs executed.")

        @sidekiq_restarted_jobs_total =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_restarted_jobs_total", "Total number of sidekiq jobs that we restarted because of a sidekiq shutdown.")

        @sidekiq_failed_jobs_total =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_failed_jobs_total", "Total number of failed sidekiq jobs.")

        @sidekiq_dead_jobs_total =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_dead_jobs_total", "Total number of dead sidekiq jobs.")
      end
    end
  end
end
