# frozen_string_literal: true

# custom type collector for prometheus_exporter for handling the metrics sent from
# PrometheusExporter::Instrumentation::Unicorn
class PrometheusExporter::Server::UnicornCollector < PrometheusExporter::Server::TypeCollector
  UNICORN_GAUGES = {
    workers_total: 'Number of unicorn workers.',
    active_workers_total: 'Number of active unicorn workers',
    request_backlog_total: 'Number of requests waiting to be processed by a unicorn worker.'
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
      UNICORN_GAUGES.map do |k, help|
        k = k.to_s
        if (v = m[k])
          g = metrics[k] ||= PrometheusExporter::Metric::Gauge.new("unicorn_#{k}", help)
          g.observe(v)
        end
      end
    end

    metrics.values
  end

  def collect(obj)
    @unicorn_metrics << obj
  end
end
