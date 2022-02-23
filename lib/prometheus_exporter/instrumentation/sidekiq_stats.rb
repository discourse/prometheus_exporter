# frozen_string_literal: true

module PrometheusExporter::Instrumentation
  class SidekiqStats < PeriodicStats
    def self.start(client: nil, frequency: 30)
      client ||= PrometheusExporter::Client.default
      sidekiq_stats_collector = new

      worker_loop do
        client.send_json(sidekiq_stats_collector.collect)
      end

      super
    end

    def collect
      {
        type: 'sidekiq_stats',
        stats: collect_stats
      }
    end

    def collect_stats
      stats = ::Sidekiq::Stats.new
      {
        'dead_size' => stats.dead_size,
        'enqueued' => stats.enqueued,
        'failed' => stats.failed,
        'processed' => stats.processed,
        'processes_size' => stats.processes_size,
        'retry_size' => stats.retry_size,
        'scheduled_size' => stats.scheduled_size,
        'workers_size' => stats.workers_size,
      }
    end
  end
end
