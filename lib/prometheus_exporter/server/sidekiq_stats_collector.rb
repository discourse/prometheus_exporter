# frozen_string_literal: true

module PrometheusExporter::Server
  class SidekiqStatsCollector < TypeCollector
    MAX_SIDEKIQ_METRIC_AGE = 60

    SIDEKIQ_STATS_GAUGES = {
      'dead_size' => 'Size of dead the queue',
      'enqueued' => 'Number of enqueued jobs',
      'failed' => 'Number of failed jobs',
      'processed' => 'Total number of processed jobs',
      'processes_size' => 'Number of processes',
      'retry_size' => 'Size of the retries queue',
      'scheduled_size' => 'Size of the scheduled queue',
      'workers_size' => 'Number of jobs actively being processed',
    }.freeze

    attr_reader :sidekiq_metrics, :gauges

    def initialize
      @sidekiq_metrics = MetricsContainer.new(ttl: MAX_SIDEKIQ_METRIC_AGE)
      @gauges = {}
    end

    def type
      'sidekiq_stats'
    end

    def metrics
      SIDEKIQ_STATS_GAUGES.each_key { |name| gauges[name]&.reset! }

      sidekiq_metrics.map do |metric|
        SIDEKIQ_STATS_GAUGES.map do |name, help|
          if (value = metric['stats'][name])
            gauge = gauges[name] ||= PrometheusExporter::Metric::Gauge.new("sidekiq_stats_#{name}", help)
            gauge.observe(value)
          end
        end
      end

      gauges.values
    end

    def collect(object)
      @sidekiq_metrics << object
    end
  end
end
