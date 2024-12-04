# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/server"
require "ostruct"

class PrometheusRunnerTest < Minitest::Test
  class MockerWebServer < OpenStruct
    def start
      true
    end
  end

  class CollectorMock < PrometheusExporter::Server::CollectorBase
    def initialize
      @collectors = []
    end

    def register_collector(collector)
      @collectors << collector
    end

    def collectors
      @collectors
    end
  end

  class WrongCollectorMock
  end

  class TypeCollectorMock < PrometheusExporter::Server::TypeCollector
    def type
      "test"
    end

    def collect(_)
      nil
    end

    def metrics
      []
    end
  end

  def teardown
    PrometheusExporter::Metric::Base.default_aggregation = nil
  end

  def test_runner_defaults
    runner = PrometheusExporter::Server::Runner.new

    assert_equal(runner.prefix, "ruby_")
    assert_equal(runner.port, 9394)
    assert_equal(runner.timeout, 2)
    assert_equal(runner.collector_class, PrometheusExporter::Server::Collector)
    assert_equal(runner.type_collectors, [])
    assert_equal(runner.verbose, false)
    assert_empty(runner.label)
    assert_nil(runner.auth)
    assert_equal(runner.realm, "Prometheus Exporter")
  end

  def test_runner_custom_options
    runner =
      PrometheusExporter::Server::Runner.new(
        prefix: "new_",
        port: 1234,
        timeout: 1,
        collector_class: CollectorMock,
        type_collectors: [TypeCollectorMock],
        verbose: true,
        label: {
          environment: "integration",
        },
        auth: "my_htpasswd_file",
        realm: "test realm",
        histogram: true,
      )

    assert_equal(runner.prefix, "new_")
    assert_equal(runner.port, 1234)
    assert_equal(runner.timeout, 1)
    assert_equal(runner.collector_class, CollectorMock)
    assert_equal(runner.type_collectors, [TypeCollectorMock])
    assert_equal(runner.verbose, true)
    assert_equal(runner.label, { environment: "integration" })
    assert_equal(runner.auth, "my_htpasswd_file")
    assert_equal(runner.realm, "test realm")
    assert_equal(runner.histogram, true)

    reset_base_metric_label
  end

  def test_runner_start
    runner =
      PrometheusExporter::Server::Runner.new(
        server_class: MockerWebServer,
        label: {
          environment: "integration",
        },
      )
    result = runner.start

    assert_equal(result, true)
    assert_equal(PrometheusExporter::Metric::Base.default_prefix, "ruby_")
    assert_equal(runner.port, 9394)
    assert_equal(runner.timeout, 2)
    assert_equal(runner.verbose, false)
    assert_nil(runner.auth)
    assert_equal(runner.realm, "Prometheus Exporter")
    assert_equal(PrometheusExporter::Metric::Base.default_labels, { environment: "integration" })
    assert_instance_of(PrometheusExporter::Server::Collector, runner.collector)

    reset_base_metric_label
  end

  def test_runner_custom_collector
    runner =
      PrometheusExporter::Server::Runner.new(
        server_class: MockerWebServer,
        collector_class: CollectorMock,
      )
    runner.start

    assert_equal(runner.collector_class, CollectorMock)
  end

  def test_runner_wrong_collector
    runner =
      PrometheusExporter::Server::Runner.new(
        server_class: MockerWebServer,
        collector_class: WrongCollectorMock,
      )

    assert_raises PrometheusExporter::Server::WrongInheritance do
      runner.start
    end
  end

  def test_runner_custom_collector_types
    runner =
      PrometheusExporter::Server::Runner.new(
        server_class: MockerWebServer,
        collector_class: CollectorMock,
        type_collectors: [TypeCollectorMock],
      )
    runner.start

    custom_collectors = runner.collector.collectors

    assert_equal(custom_collectors.size, 1)
    assert_instance_of(TypeCollectorMock, custom_collectors.first)
  end

  def test_runner_histogram_mode
    runner = PrometheusExporter::Server::Runner.new(server_class: MockerWebServer, histogram: true)
    runner.start

    assert_equal(
      PrometheusExporter::Metric::Base.default_aggregation,
      PrometheusExporter::Metric::Histogram,
    )
  end

  def reset_base_metric_label
    PrometheusExporter::Metric::Base.default_labels = {}
  end
end
