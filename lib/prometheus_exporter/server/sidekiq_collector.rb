module PrometheusExporter::Server
  class SidekiqCollector < TypeCollector

    def type
      "sidekiq"
    end

    def observe(obj)
      ensure_sidekiq_metrics
      @sidekiq_job_duration_seconds.observe(obj["duration"], job_name: obj["name"])
      @sidekiq_job_count.observe(1, job_name: obj["name"])
      @sidekiq_failed_job_count.observe(1, job_name: obj["name"]) if !obj["success"]
    end

    def metrics
      if @sidekiq_job_count
        [@sidekiq_job_duration_seconds, @sidekiq_job_count, @sidekiq_failed_job_count]
      else
        []
      end
    end

    protected

    def ensure_sidekiq_metrics
      if !@sidekiq_job_count

        @sidekiq_job_duration_seconds =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_job_duration_seconds", "Total time spent in sidekiq jobs")

        @sidekiq_job_count =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_job_count", "Total number of sidekiq jobs executed")

        @sidekiq_failed_job_count =
        PrometheusExporter::Metric::Counter.new(
          "sidekiq_failed_job_count", "Total number failed sidekiq jobs executed")
      end
    end
  end
end
