# frozen_string_literal: true

# custom type collector for prometheus_exporter for handling the metrics sent from
# PrometheusExporter::Instrumentation::Unicorn
class PrometheusExporter::Server::UnicornCollector < PrometheusExporter::Server::TypeCollector
  MAX_UNICORN_METRIC_AGE = 60

  UNICORN_GAUGES = {
    workers: 'Number of unicorn workers.',
    active_workers: 'Number of active unicorn workers',
    request_backlog: 'Number of requests waiting to be processed by a unicorn worker.'
  }.freeze

  def initialize
    @unicorn_metrics = []
  end

  def type
    'unicorn'
  end

  def metrics
    return [] if @unicorn_metrics.length.zero?

    metrics = {}

    @unicorn_metrics.map do |m|
      labels = m["custom_labels"] || {}

      UNICORN_GAUGES.map do |k, help|
        k = k.to_s
        if (v = m[k])
          g = metrics[k] ||= PrometheusExporter::Metric::Gauge.new("unicorn_#{k}", help)
          g.observe(v, labels)
        end
      end
    end

    metrics.values
  end

  def collect(obj)
    now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    obj["created_at"] = now
    @unicorn_metrics.delete_if { |m| m['created_at'] + MAX_UNICORN_METRIC_AGE < now }
    @unicorn_metrics << obj
  end
end
