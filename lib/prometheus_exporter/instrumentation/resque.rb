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
            STDERR.puts("Prometheus Exporter Failed To Collect Resque Stats #{e}")
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

      metric[:processed_jobs_total] = info[:processed]
      metric[:failed_jobs_total] = info[:failed]
      metric[:pending_jobs_total] = info[:pending]
      metric[:queues_total] = info[:queues]
      metric[:worker_total] = info[:workers]
      metric[:working_total] = info[:working]
    end
  end
end
