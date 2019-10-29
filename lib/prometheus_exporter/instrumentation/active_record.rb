# frozen_string_literal: true

# collects stats from currently running process
module PrometheusExporter::Instrumentation
  class ActiveRecord
    def self.start(client: nil, frequency: 30, labels: nil)
      metric_labels = labels || {}

      process_collector = new(metric_labels)
      client ||= PrometheusExporter::Client.default

      stop if @thread

      @thread = Thread.new do
        while true
          begin
            metric = process_collector.collect
            client.send_json metric
          rescue => e
            STDERR.puts("Prometheus Exporter Failed To Collect Process Stats #{e}")
          ensure
            sleep frequency
          end
        end
      end
    end

    def self.stop
      if t = @thread
        t.kill
        @thread = nil
      end
    end

    def initialize(metric_labels)
      @metric_labels = metric_labels
      @hostname = nil
    end

    def hostname
      @hostname ||=
        begin
          `hostname`.strip
        rescue => e
          STDERR.puts "Unable to lookup hostname #{e}"
          "unknown-host"
        end
    end

    def collect
      metric = {}
      metric[:type] = "active_record"
      metric[:metric_labels] = @metric_labels
      metric[:hostname] = hostname
      collect_active_record_pool_stats(metric)
      metric
    end

    def pid
      @pid = ::Process.pid
    end

    def collect_active_record_pool_stats(metric)
      metric[:pid] = pid
      # Pick active record from top namespace
      metric.merge!(::ActiveRecord::Base.connection_pool.stat)
    end
  end
end
