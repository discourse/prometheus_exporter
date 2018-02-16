require 'test_helper'
require 'prometheus_exporter/server/runner'

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
      'test'
    end

    def collect(_)
      nil
    end

    def metrics
      []
    end
  end


  def test_runner_defaults
    runner = PrometheusExporter::Server::Runner.new

    assert_equal(runner.prefix, 'ruby_')
    assert_equal(runner.port, 9394)
    assert_equal(runner.collector_class, PrometheusExporter::Server::Collector)
    assert_equal(runner.type_collectors, [])
    assert_equal(runner.verbose, false)
  end

  def test_runner_custom_options
    runner = PrometheusExporter::Server::Runner.new(
      prefix: 'new_',
      port: 1234,
      collector_class: CollectorMock,
      type_collectors: [TypeCollectorMock],
      verbose: true
    )

    assert_equal(runner.prefix, 'new_')
    assert_equal(runner.port, 1234)
    assert_equal(runner.collector_class, CollectorMock)
    assert_equal(runner.type_collectors, [TypeCollectorMock])
    assert_equal(runner.verbose, true)
  end

  def test_runner_start
    runner = PrometheusExporter::Server::Runner.new(server_class: MockerWebServer)
    result = runner.start

    assert_equal(result, true)
    assert_equal(PrometheusExporter::Metric::Base.default_prefix, 'ruby_')
    assert_equal(runner.port, 9394)
    assert_equal(runner.verbose, false)
    assert_instance_of(PrometheusExporter::Server::Collector, runner.collector)
  end

  def test_runner_custom_collector
    runner = PrometheusExporter::Server::Runner.new(
      server_class: MockerWebServer,
      collector_class: CollectorMock
    )
    runner.start

    assert_equal(runner.collector_class, CollectorMock)
  end

  def test_runner_wrong_collector
    runner = PrometheusExporter::Server::Runner.new(
      server_class: MockerWebServer,
      collector_class: WrongCollectorMock
    )

    assert_raises PrometheusExporter::Server::WrongInheritance do
      runner.start
    end
  end

  def test_runner_custom_collector_types
    runner = PrometheusExporter::Server::Runner.new(
      server_class: MockerWebServer,
      collector_class: CollectorMock,
      type_collectors: [TypeCollectorMock]
    )
    runner.start

    custom_collectors = runner.collector.collectors

    assert_equal(custom_collectors.size, 1)
    assert_instance_of(TypeCollectorMock, custom_collectors.first)
  end
end
