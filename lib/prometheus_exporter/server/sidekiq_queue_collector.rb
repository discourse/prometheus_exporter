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
      @sidekiq_metrics = []
      @gauges = {}
    end

    def type
      'sidekiq_queue'
    end

    def metrics
      clear_stale_metrics(reset_gauges: true)

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
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      clear_stale_metrics(time: now)

      object['queues'].each do |queue|
        queue["created_at"] = now
        queue["labels"].merge!(object['custom_labels']) if object['custom_labels']
        sidekiq_metrics << queue
      end
    end

    private

    def clear_stale_metrics(time: nil, reset_gauges: false)
      time ||= ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      sidekiq_metrics.delete_if { |metric| metric['created_at'] + MAX_SIDEKIQ_METRIC_AGE < time }

      if reset_gauges
        SIDEKIQ_QUEUE_GAUGES.each_key { |name| gauges[name]&.reset! }
      end
    end
  end
end
