# frozen_string_literal: true

# collects stats from resque
module PrometheusExporter::Instrumentation
  class Resque
    def self.start(client: nil, frequency: 30)
      resque_collector = new
      client ||= PrometheusExporter::Client.default
      Thread.new do
        while true
          begin
            client.send_json(resque_collector.collect)
          rescue => e
            client.logger.error("Prometheus Exporter Failed To Collect Resque Stats #{e}")
          ensure
            sleep frequency
          end
        end
      end
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
