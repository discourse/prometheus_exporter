module PrometheusExporter::Server
  class SidekiqQueueCollector < TypeCollector
    MAX_SIDEKIQ_METRIC_AGE = 60

    SIDEKIQ_QUEUE_GAUGES = {
      'backlog_total'   => 'Size of the sidekiq queue.',
      'latency_seconds' => 'Latency of the sidekiq queue.',
    }.freeze

    attr_reader :sidekiq_metrics, :gauges

    def initialize
      @sidekiq_metrics = []
      @gauges = {}
      SIDEKIQ_QUEUE_GAUGES.each do |name, help|
        @gauges[name] ||= PrometheusExporter::Metric::Gauge.new("sidekiq_queue_#{name}", help)
      end
    end

    def type
      'sidekiq_queue'
    end

    def metrics
      sidekiq_metrics.map do |metric|
        labels = metric.fetch("labels", {})
        SIDEKIQ_QUEUE_GAUGES.map do |name, _|
          if (value = metric[name])
            gauges[name].observe(value, labels)
          end
        end
      end

      gauges.values
    end

    def collect(object)
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      object['queues'].each do |queue|
        queue["created_at"] = now
        sidekiq_metrics << queue
        sidekiq_metrics.delete_if { |metric| metric['created_at'] + MAX_SIDEKIQ_METRIC_AGE < now }
        sidekiq_metrics << queue
      end
    end
  end
end
