# frozen_string_literal: true

# collects stats from currently running process
module PrometheusExporter::Instrumentation
  class ActiveRecord
    ALLOWED_CONFIG_LABELS = %i(database username host port)

    def self.start(client: nil, frequency: 30, custom_labels: {}, config_labels: [])

      # Not all rails versions support coonection pool stats
      unless ::ActiveRecord::Base.connection_pool.respond_to?(:stat)
        STDERR.puts("ActiveRecord connection pool stats not supported in your rails version")
        return
      end

      config_labels.map!(&:to_sym)
      validate_config_labels(config_labels)

      active_record_collector = new(custom_labels, config_labels)

      client ||= PrometheusExporter::Client.default

      stop if @thread

      @thread = Thread.new do
        while true
          begin
            metrics = active_record_collector.collect
            metrics.each { |metric| client.send_json metric }
          rescue => e
            STDERR.puts("Prometheus Exporter Failed To Collect Process Stats #{e}")
          ensure
            sleep frequency
          end
        end
      end
    end

    def self.validate_config_labels(config_labels)
      return if config_labels.size == 0
      raise "Invalid Config Labels, available options #{ALLOWED_CONFIG_LABELS}" if (config_labels - ALLOWED_CONFIG_LABELS).size > 0
    end

    def self.stop
      if t = @thread
        t.kill
        @thread = nil
      end
    end

    def initialize(metric_labels, config_labels)
      @metric_labels = metric_labels
      @config_labels = config_labels
    end

    def collect
      metrics = []
      collect_active_record_pool_stats(metrics)
      metrics
    end

    def pid
      @pid = ::Process.pid
    end

    def collect_active_record_pool_stats(metrics)
      ObjectSpace.each_object(::ActiveRecord::ConnectionAdapters::ConnectionPool) do |pool|
        next if pool.connections.nil?

        metric = {
          pid: pid,
          type: "active_record",
          hostname: ::PrometheusExporter.hostname,
          metric_labels: labels(pool)
        }
        metric.merge!(pool.stat)
        metrics << metric
      end
    end

    private

    def labels(pool)
      if ::ActiveRecord.version < Gem::Version.new("6.1.0.rc1")
        @metric_labels.merge(pool_name: pool.spec.name).merge(pool.spec.config
          .select { |k, v| @config_labels.include? k }
          .map { |k, v| [k.to_s.dup.prepend("dbconfig_"), v] }.to_h)
      else
        @metric_labels.merge(pool_name: pool.db_config.name).merge(
          @config_labels.each_with_object({}) { |l, acc| acc["dbconfig_#{l}"] = pool.db_config.public_send(l) })
      end
    end
  end
end
