# frozen_string_literal: true

# collects stats from GoodJob
module PrometheusExporter::Instrumentation
  class GoodJob < PeriodicStats
    TotalCounter = Struct.new do
      def count(relation)
        relation.size
      end
    end

    QueueCounter = Struct.new(:queue_names) do
      def initialize(queue_names)
        @empty_queues = queue_names.to_h { |name| [name, 0] }
      end

      def count(relation)
        @empty_queues.merge(relation.group(:queue_name).size)
      end
    end

    def self.start(client: nil, frequency: 30, collect_by_queue: false)
      good_job_collector = new
      client ||= PrometheusExporter::Client.default

      worker_loop do
        client.send_json(good_job_collector.collect(collect_by_queue))
      end

      super
    end

    def collect(by_queue = false)
      counter = by_queue ? QueueCounter.new(::GoodJob::Job.distinct.pluck(:queue_name)) : TotalCounter.new

      {
        type: "good_job",
        by_queue: by_queue,
        scheduled: counter.count(::GoodJob::Job.scheduled),
        retried: counter.count(::GoodJob::Job.retried),
        queued: counter.count(::GoodJob::Job.queued),
        running: counter.count(::GoodJob::Job.running),
        finished: counter.count(::GoodJob::Job.finished),
        succeeded: counter.count(::GoodJob::Job.succeeded),
        discarded: counter.count(::GoodJob::Job.discarded)
      }
    end
  end
end
