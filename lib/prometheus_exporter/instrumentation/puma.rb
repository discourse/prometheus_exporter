# frozen_string_literal: true

require "json"

# collects stats from puma
module PrometheusExporter::Instrumentation
  class Puma
    def self.start(client: nil, frequency: 30, labels: {})
      puma_collector = new(labels)
      client ||= PrometheusExporter::Client.default
      Thread.new do
        while true
          begin
            metric = puma_collector.collect
            client.send_json metric
          rescue => e
            client.logger.error("Prometheus Exporter Failed To Collect Puma Stats #{e}")
          ensure
            sleep frequency
          end
        end
      end
    end

    def initialize(metric_labels = {})
      @metric_labels = metric_labels
    end

    def collect
      metric = {
        pid: pid,
        type: "puma",
        hostname: ::PrometheusExporter.hostname,
        metric_labels: @metric_labels
      }
      collect_puma_stats(metric)
      metric
    end

    def pid
      @pid = ::Process.pid
    end

    def collect_puma_stats(metric)
      stats = JSON.parse(::Puma.stats)

      if stats.key?("workers")
        metric[:phase] = stats["phase"]
        metric[:workers_total] = stats["workers"]
        metric[:booted_workers_total] = stats["booted_workers"]
        metric[:old_workers_total] = stats["old_workers"]

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
      metric[:request_backlog_total] ||= 0
      metric[:running_threads_total] ||= 0
      metric[:thread_pool_capacity_total] ||= 0
      metric[:max_threads_total] ||= 0

      metric[:request_backlog_total] += status["backlog"]
      metric[:running_threads_total] += status["running"]
      metric[:thread_pool_capacity_total] += status["pool_capacity"]
      metric[:max_threads_total] += status["max_threads"]
    end
  end
end
