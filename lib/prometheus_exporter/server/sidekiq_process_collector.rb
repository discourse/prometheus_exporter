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
      @sidekiq_metrics = []
      @gauges = {}
    end

    def type
      'sidekiq_process'
    end

    def metrics
      clear_stale_metrics(reset_gauges: true)

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
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      clear_stale_metrics(time: now)

      process = object['process']
      process["created_at"] = now
      sidekiq_metrics << process
    end

    private

    def clear_stale_metrics(time: nil, reset_gauges: false)
      time ||= ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      sidekiq_metrics.delete_if { |metric| metric['created_at'] + MAX_SIDEKIQ_METRIC_AGE < time }

      if reset_gauges
        SIDEKIQ_PROCESS_GAUGES.each_key { |name| gauges[name]&.reset! }
      end
    end
  end
end
