# frozen_string_literal: true
module PrometheusExporter::Server
  class SidekiqQueueCollector < TypeCollector
    MAX_SIDEKIQ_METRIC_AGE = 60

    SIDEKIQ_QUEUE_GAUGES = {
      'backlog' => 'Size of the sidekiq queue.',
      'latency_seconds' => 'Latency of the sidekiq queue.',
    }.freeze

    attr_reader :sidekiq_metrics, :gauges

    def initialize
      @sidekiq_metrics = MetricsContainer.new
      @gauges = {}
    end

    def type
      'sidekiq_queue'
    end

    def metrics
      SIDEKIQ_QUEUE_GAUGES.each_key { |name| gauges[name]&.reset! }

      sidekiq_metrics.map do |metric|
        labels = metric.fetch("labels", {})
        SIDEKIQ_QUEUE_GAUGES.map do |name, help|
          if (value = metric[name])
            gauge = gauges[name] ||= PrometheusExporter::Metric::Gauge.new("sidekiq_queue_#{name}", help)
            gauge.observe(value, labels)
          end
        end
      end

      gauges.values
    end

    def collect(object)
      object['queues'].each do |queue|
        queue["labels"].merge!(object['custom_labels']) if object['custom_labels']
        @sidekiq_metrics << queue
      end
    end
  end
end
