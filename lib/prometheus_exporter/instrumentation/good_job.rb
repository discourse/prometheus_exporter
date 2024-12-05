# frozen_string_literal: true

# collects stats from GoodJob
module PrometheusExporter::Instrumentation
  class GoodJob < PeriodicStats
    def self.start(client: nil, frequency: 30)
      good_job_collector = new
      client ||= PrometheusExporter::Client.default

      worker_loop { client.send_json(good_job_collector.collect) }

      super
    end

    def collect
      {
        type: "good_job",
        scheduled: ::GoodJob::Job.scheduled.size,
        retried: ::GoodJob::Job.retried.size,
        queued: ::GoodJob::Job.queued.size,
        running: ::GoodJob::Job.running.size,
        finished: ::GoodJob::Job.finished.size,
        succeeded: ::GoodJob::Job.succeeded.size,
        discarded: ::GoodJob::Job.discarded.size,
      }
    end
  end
end
