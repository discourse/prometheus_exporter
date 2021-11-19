# frozen_string_literal: true

require 'test_helper'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusSidekiqProcessCollectorTest < Minitest::Test
  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
  end

  def collector
    @collector ||= PrometheusExporter::Server::SidekiqProcessCollector.new
  end

  def test_collecting_metrics
    collector.collect(
      'process' => {
        'busy' => 1,
        'concurrency' => 2,
        'labels' => {
          'labels' => 'lab_1,lab_2',
          'queues' => 'default,reliable',
          'quiet' => 'false',
          'tag' => 'default',
          'hostname' => 'sidekiq-1234',
          'identity' => 'sidekiq-1234:1',
        }
      }
    )

    metrics = collector.metrics
    expected = [
      'sidekiq_process_busy{labels="lab_1,lab_2",queues="default,reliable",quiet="false",tag="default",hostname="sidekiq-1234",identity="sidekiq-1234:1"} 1',
      'sidekiq_process_concurrency{labels="lab_1,lab_2",queues="default,reliable",quiet="false",tag="default",hostname="sidekiq-1234",identity="sidekiq-1234:1"} 2',
    ]
    assert_equal expected, metrics.map(&:metric_text)
  end

  def test_only_fresh_metrics_are_collected
    Process.stub(:clock_gettime, 1.0) do
      collector.collect(
        'process' => {
          'busy' => 1,
          'concurrency' => 2,
          'labels' => {
            'labels' => 'lab_1,lab_2',
            'queues' => 'default,reliable',
            'quiet' => 'false',
            'tag' => 'default',
            'hostname' => 'sidekiq-1234',
            'identity' => 'sidekiq-1234:1',
          }
        }
      )
    end

    Process.stub(:clock_gettime, 2.0 + PrometheusExporter::Server::SidekiqQueueCollector::MAX_SIDEKIQ_METRIC_AGE) do
      collector.collect(
        'process' => {
          'busy' => 2,
          'concurrency' => 2,
          'labels' => {
            'labels' => 'other_label',
            'queues' => 'default,reliable',
            'quiet' => 'true',
            'tag' => 'default',
            'hostname' => 'sidekiq-1234',
            'identity' => 'sidekiq-1234:1',
          }
        }
      )

      metrics = collector.metrics
      expected = [
        'sidekiq_process_busy{labels="other_label",queues="default,reliable",quiet="true",tag="default",hostname="sidekiq-1234",identity="sidekiq-1234:1"} 2',
        'sidekiq_process_concurrency{labels="other_label",queues="default,reliable",quiet="true",tag="default",hostname="sidekiq-1234",identity="sidekiq-1234:1"} 2'
      ]
      assert_equal expected, metrics.map(&:metric_text)
    end
  end
end
