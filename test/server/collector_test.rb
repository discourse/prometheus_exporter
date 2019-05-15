# frozen_string_literal: true

require 'test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/client'
require 'prometheus_exporter/instrumentation'

class PrometheusCollectorTest < Minitest::Test

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
  end

  class PipedClient
    def initialize(collector, custom_labels: nil)
      @collector = collector
      @custom_labels = custom_labels
    end

    def send_json(obj)
      payload = obj.merge(custom_labels: @custom_labels).to_json
      @collector.process(payload)
    end
  end

  def test_local_metric
    collector = PrometheusExporter::Server::Collector.new
    client = PrometheusExporter::LocalClient.new(collector: collector)

    PrometheusExporter::Instrumentation::Process.start(client: client, labels: { hello: "custom label" })

    metrics_text = ""
    TestHelper.wait_for(2) do
      metrics_text = collector.prometheus_metrics_text
      metrics_text != ""
    end

    PrometheusExporter::Instrumentation::Process.stop

    assert(metrics_text.match?(/heap_live_slots/))
    assert(metrics_text.match?(/hello.*custom label/))
  end

  def test_register_metric
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new("amazing", "amount of amazing")
    collector.register_metric(metric)
    metric.observe(77)
    metric.observe(2, red: "alert")
    text = <<~TXT
      # HELP amazing amount of amazing
      # TYPE amazing gauge
      amazing 77
      amazing{red="alert"} 2
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_increment_gauge_when_specified
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new(name, help)
    collector.register_metric(metric)
    json = {
      type: :gauge,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      prometheus_exporter_action: :increment,
      value: 1
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name gauge
      test_name{key1="test1"} 2
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_decrement_gauge_when_specified
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new(name, help)
    collector.register_metric(metric)
    json = {
      type: :gauge,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      prometheus_exporter_action: :decrement,
      value: 5
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name gauge
      test_name{key1="test1"} -10
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_collect_sidekiq_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector)

    instrument = PrometheusExporter::Instrumentation::Sidekiq.new(client: client)

    instrument.call("hello", nil, "default") do
      # nothing
    end

    begin
      instrument.call(false, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("sidekiq_failed_jobs_total{job_name=\"FalseClass\"} 1"), "has failed job")

    assert(result.include?("sidekiq_jobs_total{job_name=\"String\"} 1"), "has working job")
    assert(result.include?("sidekiq_job_duration_seconds"), "has duration")
  end

  def test_it_can_collect_sidekiq_metrics_with_custom_labels
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    instrument = PrometheusExporter::Instrumentation::Sidekiq.new(client: client)

    instrument.call("hello", nil, "default") do
      # nothing
    end

    begin
      instrument.call(false, nil, "default") do
        boom
      end
    rescue
    end

    active_job_worker = {}
    active_job_worker.stub(:class, "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper") do
      instrument.call(active_job_worker, { 'wrapped' => 'WrappedClass' }, "default") do
        # nothing
      end
    end

    result = collector.prometheus_metrics_text

    assert(result.include?('sidekiq_failed_jobs_total{job_name="FalseClass",service="service1"} 1'), "has failed job")
    assert(result.include?('sidekiq_jobs_total{job_name="String",service="service1"} 1'), "has working job")
    assert(result.include?('sidekiq_job_duration_seconds{job_name="FalseClass",service="service1"}'), "has duration")
    assert(result.include?('sidekiq_jobs_total{job_name="WrappedClass",service="service1"} 1'), "has sidekiq working job from ActiveJob")
  end

  def test_it_merges_custom_labels_for_generic_metrics
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new(name, help)
    collector.register_metric(metric)
    json = {
      type: :gauge,
      help: help,
      name: name,
      custom_labels: { host: "example.com" },
      keys: { key1: 'test1' },
      value: 5
    }.to_json

    collector.process(json)

    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name gauge
      test_name{host="example.com",key1="test1"} 5
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_collect_process_metrics
    # make some mini racer data
    ctx = MiniRacer::Context.new
    ctx.eval("1")

    collector = PrometheusExporter::Server::Collector.new

    process_instrumentation = PrometheusExporter::Instrumentation::Process.new(type: "web")
    collected = process_instrumentation.collect

    collector.process(collected.to_json)

    text = collector.prometheus_metrics_text

    v8_str = "v8_heap_count{type=\"web\",pid=\"#{collected[:pid]}\"} #{collected[:v8_heap_count]}"

    assert(text.include?(v8_str), "must include v8 metric")
    assert(text.include?("minor_gc_ops_total"), "must include counters")
  end

  def test_it_can_collect_delayed_job_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector)

    instrument = PrometheusExporter::Instrumentation::DelayedJob.new(client: client)

    job = Minitest::Mock.new
    job.expect(:handler, "job_class: Class")
    job.expect(:attempts, 0)

    instrument.call(job, 20, nil, "default") do
      # nothing
    end

    failed_job = Minitest::Mock.new
    failed_job.expect(:handler, "job_class: Object")
    failed_job.expect(:attempts, 1)

    begin
      instrument.call(failed_job, 25, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("delayed_failed_jobs_total{job_name=\"Object\"} 1"), "has failed job")
    assert(result.include?("delayed_jobs_total{job_name=\"Class\"} 1"), "has working job")
    assert(result.include?("delayed_job_duration_seconds"), "has duration")
    job.verify
    failed_job.verify
  end

  def test_it_can_collect_delayed_job_metrics_with_custom_labels
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    instrument = PrometheusExporter::Instrumentation::DelayedJob.new(client: client)

    job = Minitest::Mock.new
    job.expect(:handler, "job_class: Class")
    job.expect(:attempts, 0)

    instrument.call(job, 25, nil, "default") do
      # nothing
    end

    failed_job = Minitest::Mock.new
    failed_job.expect(:handler, "job_class: Object")
    failed_job.expect(:attempts, 1)

    begin
      instrument.call(failed_job, 25, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?('delayed_failed_jobs_total{job_name="Object",service="service1"} 1'), "has failed job")
    assert(result.include?('delayed_jobs_total{job_name="Class",service="service1"} 1'), "has working job")
    assert(result.include?('delayed_job_duration_seconds{job_name="Class",service="service1"}'), "has duration")
    job.verify
    failed_job.verify
  end

  require 'minitest/stub_const'

  def test_it_can_collect_puma_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    mock_puma = Minitest::Mock.new
    mock_puma.expect(
      :stats,
      '{ "workers": 1, "phase": 0, "booted_workers": 1, "old_workers": 0, "worker_status": [{ "pid": 87819, "index": 0, "phase": 0, "booted": true, "last_checkin": "2018-10-16T11:50:31Z", "last_status": { "backlog":0, "running":8, "pool_capacity":32, "max_threads": 32 } }] }'
    )

    instrument = PrometheusExporter::Instrumentation::Puma.new

    Object.stub_const(:Puma, mock_puma) do
      metric = instrument.collect
      client.send_json metric
    end

    result = collector.prometheus_metrics_text
    assert(result.include?('puma_booted_workers_total{phase="0",service="service1"} 1'), "has booted workers")
    assert(result.include?('puma_request_backlog_total{phase="0",service="service1"} 0'), "has total backlog")
    assert(result.include?('puma_thread_pool_capacity_total{phase="0",service="service1"} 32'), "has pool capacity")
    mock_puma.verify
  end
end
