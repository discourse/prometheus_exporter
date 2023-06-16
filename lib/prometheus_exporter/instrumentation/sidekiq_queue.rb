# frozen_string_literal: true

module PrometheusExporter::Instrumentation
  class SidekiqQueue < PeriodicStats
    def self.start(client: nil, frequency: 30, all_queues: false)
      client ||= PrometheusExporter::Client.default
      sidekiq_queue_collector = new(all_queues: all_queues)

      worker_loop do
        client.send_json(sidekiq_queue_collector.collect)
      end

      super
    end

    def initialize(all_queues: false)
      @all_queues = all_queues
      @pid = ::Process.pid
      @hostname = Socket.gethostname
    end

    def collect
      {
        type: 'sidekiq_queue',
        queues: collect_queue_stats
      }
    end

    def collect_queue_stats
      sidekiq_queues = ::Sidekiq::Queue.all

      unless @all_queues
        queues = collect_current_process_queues
        sidekiq_queues.select! { |sidekiq_queue| queues.include?(sidekiq_queue.name) }
      end

      sidekiq_queues.map do |queue|
        {
          backlog: queue.size,
          latency_seconds: queue.latency.to_i,
          labels: { queue: queue.name }
        }
      end.compact
    end

    private

    def collect_current_process_queues
      ps = ::Sidekiq::ProcessSet.new

      process = ps.find do |sp|
        sp['hostname'] == @hostname && sp['pid'] == @pid
      end

      process.nil? ? [] : process['queues']
    end
  end
end
