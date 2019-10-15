# frozen_string_literal: true

begin
  require 'raindrops'
rescue LoadError
  # No raindrops available, dont do anything
end

module PrometheusExporter::Instrumentation
  # collects stats from unicorn
  class Unicorn
    def self.start(pid_file:, listener_address:, client: nil, frequency: 30)
      unicorn_collector = new(pid_file: pid_file, listener_address: listener_address)
      client ||= PrometheusExporter::Client.default
      Thread.new do
        loop do
          begin
            metric = unicorn_collector.collect
            client.send_json metric
          rescue StandardError => e
            STDERR.puts("Prometheus Exporter Failed To Collect Unicorn Stats #{e}")
          ensure
            sleep frequency
          end
        end
      end
    end

    def initialize(pid_file:, listener_address:)
      @pid_file = pid_file
      @listener_address = listener_address
      @tcp = listener_address =~ /\A.+:\d+\z/
    end

    def collect
      metric = {}
      metric[:type] = 'unicorn'
      collect_unicorn_stats(metric)
      metric
    end

    def collect_unicorn_stats(metric)
      stats = listener_address_stats

      metric[:active_workers_total] = stats.active
      metric[:request_backlog_total] = stats.queued
      metric[:workers_total] = worker_process_count
    end

    private

    def worker_process_count
      return nil unless File.exist?(@pid_file)
      pid = File.read(@pid_file).to_i

      return nil if pid < 1

      # find all processes whose parent is the unicorn master
      # but we're actually only interested in the number of processes (= lines of output)
      result = `pgrep -P #{pid} -f unicorn -a`
      result.lines.count
    end

    def listener_address_stats
      if @tcp
        Raindrops::Linux.tcp_listener_stats([@listener_address])[@listener_address]
      else
        Raindrops::Linux.unix_listener_stats([@listener_address])[@listener_address]
      end
    end
  end
end
