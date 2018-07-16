module PrometheusExporter::Server
  class SidekiqCollector < TypeCollector

    def type
      "sidekiq"
    end

    def collect(obj)
      default_labels = { job_name: obj['name'] }
      custom_labels = obj['custom_labels']
      labels = custom_labels.nil? ? default_labels : default_labels.merge(custom_labels)

      ensure_sidekiq_metrics
      @sidekiq_job_duration_seconds.observe(obj["duration"], labels)
      @sidekiq_jobs_total.observe(1, labels)
      @sidekiq_failed_jobs_total.observe(1, labels) if !obj["success"]
    end

    def metrics
      if @sidekiq_jobs_total
        [@sidekiq_job_duration_seconds, @sidekiq_jobs_total, @sidekiq_failed_jobs_total]
      else
        []
      end
    end

    protected

    def ensure_sidekiq_metrics
      if !@sidekiq_jobs_total

        @sidekiq_job_duration_seconds =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_job_duration_seconds", "Total time spent in sidekiq jobs.")

        @sidekiq_jobs_total =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_jobs_total", "Total number of sidekiq jobs executed.")

        @sidekiq_failed_jobs_total =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_failed_jobs_total", "Total number failed sidekiq jobs executed.")
      end
    end
  end
end
