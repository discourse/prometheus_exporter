require 'json'

# collects stats from puma
module PrometheusExporter::Instrumentation
  class Puma
    def self.start(client: nil, frequency: 30)
      puma_collector = new
      client ||= PrometheusExporter::Client.default
      Thread.new do
        while true
          begin
            metric = puma_collector.collect
            client.send_json metric
          rescue => e
            STDERR.puts("Prometheus Exporter Failed To Collect Puma Stats #{e}")
          ensure
            sleep frequency
          end
        end
      end
    end

    def collect
      metric = {}
      metric[:type] = "puma"
      collect_puma_stats(metric)
      metric
    end

    def collect_puma_stats(metric)
      stats = JSON.parse(::Puma.stats)

      if stats.key? 'workers'
        metric[:phase] = stats["phase"]
        metric[:workers] = stats["workers"]
        metric[:booted_workers] = stats["booted_workers"]
        metric[:old_workers] = stats["old_workers"]

        stats["worker_status"].each do |worker|
          next if worker["last_status"].empty?
          collect_worker_status(metric, worker["last_status"])
        end
      else
        collect_worker_status(metric, stats)
      end
    end

    private

    def collect_worker_status(metric, status)
      metric[:backlog] ||= 0
      metric[:running] ||= 0
      metric[:pool_capacity] ||= 0
      metric[:max_threads] ||= 0

      metric[:backlog] += status["backlog"]
      metric[:running] += status["running"]
      metric[:pool_capacity] += status["pool_capacity"]
      metric[:max_threads] += status["max_threads"]
    end
  end
end
