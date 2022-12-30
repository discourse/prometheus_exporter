# frozen_string_literal: true

module PrometheusExporter::Server
  class SidekiqProcessCollector < PrometheusExporter::Server::TypeCollector
    MAX_SIDEKIQ_METRIC_AGE = 60

    SIDEKIQ_PROCESS_GAUGES = {
      'busy' => 'Number of running jobs',
      'concurrency' => 'Maximum concurrency',
    }.freeze

    attr_reader :sidekiq_metrics, :gauges

    def initialize
      @sidekiq_metrics = MetricsContainer.new(ttl: MAX_SIDEKIQ_METRIC_AGE)
      @gauges = {}
    end

    def type
      'sidekiq_process'
    end

    def metrics
      SIDEKIQ_PROCESS_GAUGES.each_key { |name| gauges[name]&.reset! }

      sidekiq_metrics.map do |metric|
        labels = metric.fetch('labels', {})
        SIDEKIQ_PROCESS_GAUGES.map do |name, help|
          if (value = metric[name])
            gauge = gauges[name] ||= PrometheusExporter::Metric::Gauge.new("sidekiq_process_#{name}", help)
            gauge.observe(value, labels)
          end
        end
      end

      gauges.values
    end

    def collect(object)
      @sidekiq_metrics << object["process"]
    end
  end
end
