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
    end

    def metrics
      if @delayed_jobs_total
        [@delayed_job_duration_seconds, @delayed_jobs_total, @delayed_failed_jobs_total]
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
      end
    end
  end
end
