# frozen_string_literal: true

module PrometheusExporter::Server
  class DelayedJobCollector < TypeCollector
    def initialize
      @delayed_jobs_total = nil
      @delayed_job_duration_seconds = nil
      @delayed_jobs_total = nil
      @delayed_failed_jobs_total = nil
      @delayed_jobs_max_attempts_reached_total = nil
      @delayed_job_duration_seconds_summary = nil
      @delayed_job_attempts_summary = nil
      @delayed_jobs_enqueued = nil
      @delayed_jobs_pending = nil
    end

    def type
      "delayed_job"
    end

    def collect(obj)
      custom_labels = obj['custom_labels'] || {}
      gauge_labels = { queue_name: obj['queue_name'] }.merge(custom_labels)
      counter_labels = gauge_labels.merge(job_name: obj['name'])

      ensure_delayed_job_metrics
      @delayed_job_duration_seconds.observe(obj["duration"], counter_labels)
      @delayed_jobs_total.observe(1, counter_labels)
      @delayed_failed_jobs_total.observe(1, counter_labels) if !obj["success"]
      @delayed_jobs_max_attempts_reached_total.observe(1, counter_labels) if obj["attempts"] >= obj["max_attempts"]
      @delayed_job_duration_seconds_summary.observe(obj["duration"], counter_labels)
      @delayed_job_duration_seconds_summary.observe(obj["duration"], counter_labels.merge(status: "success")) if obj["success"]
      @delayed_job_duration_seconds_summary.observe(obj["duration"], counter_labels.merge(status: "failed"))  if !obj["success"]
      @delayed_job_attempts_summary.observe(obj["attempts"], counter_labels) if obj["success"]
      @delayed_jobs_enqueued.observe(obj["enqueued"], gauge_labels)
      @delayed_jobs_pending.observe(obj["pending"], gauge_labels)
    end

    def metrics
      if @delayed_jobs_total
        [@delayed_job_duration_seconds, @delayed_jobs_total, @delayed_failed_jobs_total,
         @delayed_jobs_max_attempts_reached_total, @delayed_job_duration_seconds_summary, @delayed_job_attempts_summary,
         @delayed_jobs_enqueued, @delayed_jobs_pending]
      else
        []
      end
    end

    protected

    def ensure_delayed_job_metrics
      if !@delayed_jobs_total

        @delayed_job_duration_seconds =
        PrometheusExporter::Metric::Counter.new(
          "delayed_job_duration_seconds", "Total time spent in delayed jobs.")

        @delayed_jobs_total =
        PrometheusExporter::Metric::Counter.new(
          "delayed_jobs_total", "Total number of delayed jobs executed.")

        @delayed_jobs_enqueued =
        PrometheusExporter::Metric::Gauge.new(
          "delayed_jobs_enqueued", "Number of enqueued delayed jobs.")

        @delayed_jobs_pending =
        PrometheusExporter::Metric::Gauge.new(
          "delayed_jobs_pending", "Number of pending delayed jobs.")

        @delayed_failed_jobs_total =
        PrometheusExporter::Metric::Counter.new(
          "delayed_failed_jobs_total", "Total number failed delayed jobs executed.")

        @delayed_jobs_max_attempts_reached_total =
            PrometheusExporter::Metric::Counter.new(
                "delayed_jobs_max_attempts_reached_total", "Total number of delayed jobs that reached max attempts.")

        @delayed_job_duration_seconds_summary =
            PrometheusExporter::Metric::Base.default_aggregation.new("delayed_job_duration_seconds_summary",
                                                                     "Summary of the time it takes jobs to execute.")

        @delayed_job_attempts_summary =
            PrometheusExporter::Metric::Base.default_aggregation.new("delayed_job_attempts_summary",
                                                                     "Summary of the amount of attempts it takes delayed jobs to succeed.")
      end
    end
  end
end
