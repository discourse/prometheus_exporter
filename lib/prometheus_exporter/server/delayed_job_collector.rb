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
      @delayed_jobs_failed = nil
      @delayed_jobs_max_failed = nil
    end

    def type
      "delayed_job"
    end

    def collect(obj)
      default_labels = { job_name: obj['name'], queue_name: obj['queue_name'] }
      custom_labels = obj['custom_labels']

      labels = custom_labels.nil? ? default_labels : default_labels.merge(custom_labels)

      ensure_delayed_job_metrics
      @delayed_job_duration_seconds.observe(obj["duration"], labels)
      @delayed_jobs_total.observe(1, labels)
      @delayed_failed_jobs_total.observe(1, labels) if !obj["success"]
      @delayed_jobs_max_attempts_reached_total.observe(1, labels) if obj["attempts"] >= obj["max_attempts"]
      @delayed_job_duration_seconds_summary.observe(obj["duration"], labels)
      @delayed_job_duration_seconds_summary.observe(obj["duration"], labels.merge(status: "success")) if obj["success"]
      @delayed_job_duration_seconds_summary.observe(obj["duration"], labels.merge(status: "failed"))  if !obj["success"]
      @delayed_job_attempts_summary.observe(obj["attempts"], labels) if obj["success"]
      @delayed_jobs_enqueued.observe(obj["enqueued"], labels)
      @delayed_jobs_pending.observe(obj["pending"], labels)
      @delayed_jobs_failed.observe(obj["failed"], labels)
      @delayed_jobs_max_failed.observe(obj["max_failed"], labels)
    end

    def metrics
      if @delayed_jobs_total
        [@delayed_job_duration_seconds, @delayed_jobs_total, @delayed_failed_jobs_total,
         @delayed_jobs_max_attempts_reached_total, @delayed_job_duration_seconds_summary, @delayed_job_attempts_summary,
         @delayed_jobs_enqueued, @delayed_jobs_pending, @delayed_jobs_failed, @delayed_jobs_max_failed]
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

        @delayed_jobs_failed =
        PrometheusExporter::Metric::Gauge.new(
          "delayed_jobs_failed", "Number of failed delayed jobs.")

        @delayed_jobs_max_failed =
        PrometheusExporter::Metric::Gauge.new(
          "delayed_jobs_max_failed", "Number of failed delayed jobs without more retries.")

        @delayed_failed_jobs_total =
        PrometheusExporter::Metric::Counter.new(
          "delayed_failed_jobs_total", "Total number failed delayed jobs executed.")

        @delayed_jobs_max_attempts_reached_total =
            PrometheusExporter::Metric::Counter.new(
                "delayed_jobs_max_attempts_reached_total", "Total number of delayed jobs that reached max attempts.")

        @delayed_job_duration_seconds_summary =
            PrometheusExporter::Metric::Summary.new("delayed_job_duration_seconds_summary",
                                                    "Summary of the time it takes jobs to execute.")

        @delayed_job_attempts_summary =
            PrometheusExporter::Metric::Summary.new("delayed_job_attempts_summary",
                                                    "Summary of the amount of attempts it takes delayed jobs to succeed.")
      end
    end
  end
end
