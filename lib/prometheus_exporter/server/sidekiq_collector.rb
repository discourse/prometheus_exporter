module PrometheusExporter::Server
  class SidekiqCollector < TypeCollector

    def type
      "sidekiq"
    end

    def collect(obj)
      ensure_sidekiq_metrics
      @sidekiq_job_duration_seconds.observe(obj["duration"], job_name: obj["name"])
      @sidekiq_jobs_total.observe(1, job_name: obj["name"])
      @sidekiq_failed_jobs_total.observe(1, job_name: obj["name"]) if !obj["success"]
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
