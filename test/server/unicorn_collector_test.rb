require 'test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusUnicornCollectorTest < Minitest::Test
  def collector
    @collector ||= PrometheusExporter::Server::UnicornCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      'workers_total' => 4,
      'active_workers_total' => 3,
      'request_backlog_total' => 0
    )

    metrics = collector.metrics

    expected = [
      'unicorn_workers_total 4',
      'unicorn_active_workers_total 3',
      'unicorn_request_backlog_total 0'
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end
end
