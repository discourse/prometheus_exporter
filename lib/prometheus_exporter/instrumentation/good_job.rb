# frozen_string_literal: true

# collects stats from GoodJob
module PrometheusExporter::Instrumentation
  class GoodJob < PeriodicStats
    COUNT_BY_QUEUE = ->(collection) { collection.group(:queue_name).size }
    COUNT_ALL = ->(collection) { collection.size }

    def self.start(client: nil, frequency: 30, collect_by_queue: false)
      good_job_collector = new
      client ||= PrometheusExporter::Client.default

      worker_loop do
        client.send_json(good_job_collector.collect(collect_by_queue))
      end

      super
    end

    def collect(by_queue = false)
      count_method = by_queue ? COUNT_BY_QUEUE : COUNT_ALL
      {
        type: "good_job",
        by_queue: by_queue,
        scheduled: ::GoodJob::Job.scheduled.yield_self(&count_method),
        retried: ::GoodJob::Job.retried.yield_self(&count_method),
        queued: ::GoodJob::Job.queued.yield_self(&count_method),
        running: ::GoodJob::Job.running.yield_self(&count_method),
        finished: ::GoodJob::Job.finished.yield_self(&count_method),
        succeeded: ::GoodJob::Job.succeeded.yield_self(&count_method),
        discarded: ::GoodJob::Job.discarded.yield_self(&count_method)
      }
    end
  end
end
