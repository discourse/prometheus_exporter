module PrometheusExporter::Server
  class DelayedJobCollector < TypeCollector

    def type
      "delayed_job"
    end

    def collect(obj)
      default_labels = { job_name: obj['name'] }
      custom_labels = obj['custom_labels']
      labels = custom_labels.nil? ? default_labels : default_labels.merge(custom_labels)

      ensure_delayed_job_metrics
      @delayed_job_duration_seconds.observe(obj["duration"], labels)
      @delayed_jobs_total.observe(1, labels)
      @delayed_failed_jobs_total.observe(1, labels) if !obj["success"]
      @delayed_jobs_max_attempts_reached_total.observe(1) if obj["attempts"] >= obj["max_attempts"]
      @delayed_job_duration_seconds_summary.observe(obj["duration"])
      @delayed_job_duration_seconds_summary.observe(obj["duration"], status: "success") if obj["success"]
      @delayed_job_duration_seconds_summary.observe(obj["duration"], status: "failed")  if !obj["success"]
      @delayed_job_attempts_summary.observe(obj["attempts"]) if obj["success"]
    end

    def metrics
      if @delayed_jobs_total
        [@delayed_job_duration_seconds, @delayed_jobs_total, @delayed_failed_jobs_total,
         @delayed_jobs_max_attempts_reached_total, @delayed_job_duration_seconds_summary, @delayed_job_attempts_summary]
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
