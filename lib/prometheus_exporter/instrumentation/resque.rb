# frozen_string_literal: true

# collects stats from resque
module PrometheusExporter::Instrumentation
  class Resque < PeriodicStats
    def self.start(client: nil, frequency: 30)
      resque_collector = new
      client ||= PrometheusExporter::Client.default

      worker_loop do
        client.send_json(resque_collector.collect)
      end

      super
    end

    def collect
      metric = {}
      metric[:type] = "resque"
      collect_resque_stats(metric)
      metric
    end

    def collect_resque_stats(metric)
      info = ::Resque.info

      metric[:processed_jobs] = info[:processed]
      metric[:failed_jobs] = info[:failed]
      metric[:pending_jobs] = info[:pending]
      metric[:queues] = info[:queues]
      metric[:worker] = info[:workers]
      metric[:working] = info[:working]
    end
  end
end
