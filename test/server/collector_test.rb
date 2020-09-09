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

    assert_match(/heap_live_slots/, metrics_text)
    assert_match(/hello.*custom label/, metrics_text)
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

  def test_it_can_export_summary_stats
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    json = {
      type: :summary,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      value: 0.6
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name summary
      test_name{key1=\"test1\",quantile=\"0.99\"} 0.6
      test_name{key1=\"test1\",quantile=\"0.9\"} 0.6
      test_name{key1=\"test1\",quantile=\"0.5\"} 0.6
      test_name{key1=\"test1\",quantile=\"0.1\"} 0.6
      test_name{key1=\"test1\",quantile=\"0.01\"} 0.6
      test_name_sum{key1=\"test1\"} 1.2
      test_name_count{key1=\"test1\"} 2
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_pass_options_to_summary
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    json = {
      type: :summary,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      opts: { quantiles: [0.75, 0.5, 0.25] },
      value: 8
    }
    collector.process(json.to_json)

    %w[3 3 5 8 1 7 9 1 2 6 4 0 2 8 3 6 4 2 4 5 4 8 9 1 4 7 3 6 1 5 6 4].each do |num|
      json[:value] = num.to_i
      collector.process(json.to_json)
    end

    # In this case our 0 to 10 based data is skewed a bit low
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name summary
      test_name{key1=\"test1\",quantile=\"0.75\"} 6.0
      test_name{key1=\"test1\",quantile=\"0.5\"} 4.0
      test_name{key1=\"test1\",quantile=\"0.25\"} 3.0
      test_name_sum{key1=\"test1\"} 149.0
      test_name_count{key1=\"test1\"} 33
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_export_histogram_stats
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    json = {
      type: :histogram,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      value: 6
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name histogram
      test_name_bucket{key1=\"test1\",le=\"+Inf\"} 2
      test_name_bucket{key1=\"test1\",le=\"10.0\"} 2
      test_name_bucket{key1=\"test1\",le=\"5.0\"} 0
      test_name_bucket{key1=\"test1\",le=\"2.5\"} 0
      test_name_bucket{key1=\"test1\",le=\"1\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.5\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.25\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.1\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.05\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.025\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.01\"} 0
      test_name_bucket{key1=\"test1\",le=\"0.005\"} 0
      test_name_count{key1=\"test1\"} 2
      test_name_sum{key1=\"test1\"} 12.0
    TXT

    assert_equal(text, collector.prometheus_metrics_text)
  end

  def test_it_can_pass_options_to_histogram
    name = 'test_name'
    help = 'test_help'
    collector = PrometheusExporter::Server::Collector.new
    json = {
      type: :histogram,
      help: help,
      name: name,
      keys: { key1: 'test1' },
      opts: { buckets: [5, 6, 7] },
      value: 6
    }.to_json

    collector.process(json)
    collector.process(json)
    text = <<~TXT
      # HELP test_name test_help
      # TYPE test_name histogram
      test_name_bucket{key1=\"test1\",le=\"+Inf\"} 2
      test_name_bucket{key1=\"test1\",le=\"7\"} 2
      test_name_bucket{key1=\"test1\",le=\"6\"} 2
      test_name_bucket{key1=\"test1\",le=\"5\"} 0
      test_name_count{key1=\"test1\"} 2
      test_name_sum{key1=\"test1\"} 12.0
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

    delayed_worker = {}
    delayed_worker.stub(:class, "Sidekiq::Extensions::DelayedClass") do
      instrument.call(delayed_worker, { 'args' => [ "---\n- !ruby/class 'String'\n- :foo\n- -" ] }, "default") do
        # nothing
      end
    end

    result = collector.prometheus_metrics_text

    assert(result.include?('sidekiq_failed_jobs_total{job_name="FalseClass",service="service1"} 1'), "has failed job")
    assert(result.include?('sidekiq_jobs_total{job_name="String",service="service1"} 1'), "has working job")
    assert(result.include?('sidekiq_job_duration_seconds{job_name="FalseClass",service="service1"}'), "has duration")
    assert(result.include?('sidekiq_jobs_total{job_name="WrappedClass",service="service1"} 1'), "has sidekiq working job from ActiveJob")
    assert(result.include?('sidekiq_jobs_total{job_name="String#foo",service="service1"} 1'), "has sidekiq delayed class")
  end

  def test_it_can_collect_shoryuken_metrics_with_custom_lables
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector, custom_labels: { service: 'service1' })

    instrument = PrometheusExporter::Instrumentation::Shoryuken.new(client: client)

    instrument.call("hello", nil, "default", "body") do
    end
    begin
      instrument.call(false, nil, "default", "body") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("shoryuken_failed_jobs_total{job_name=\"FalseClass\",queue_name=\"\",service=\"service1\"} 1"), "has failed job")
    assert(result.include?("shoryuken_jobs_total{job_name=\"String\",queue_name=\"\",service=\"service1\"} 1"), "has working job")
    assert(result.include?("shoryuken_job_duration_seconds{job_name=\"String\",queue_name=\"\",service=\"service1\"} "), "has duration")
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

    instrument.call(job, 20, 10, 0, nil, "default") do
      # nothing
    end

    failed_job = Minitest::Mock.new
    failed_job.expect(:handler, "job_class: Object")
    failed_job.expect(:attempts, 1)

    begin
      instrument.call(failed_job, 25, 10, 0, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("delayed_failed_jobs_total{job_name=\"Object\"} 1"), "has failed job")
    assert(result.include?("delayed_jobs_total{job_name=\"Class\"} 1"), "has working job")
    assert(result.include?("delayed_job_duration_seconds"), "has duration")
    assert(result.include?("delayed_jobs_enqueued 10"), "has enqueued count")
    assert(result.include?("delayed_jobs_pending 0"), "has pending count")
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

    instrument.call(job, 25, 10, 0, nil, "default") do
      # nothing
    end

    failed_job = Minitest::Mock.new
    failed_job.expect(:handler, "job_class: Object")
    failed_job.expect(:attempts, 1)

    begin
      instrument.call(failed_job, 25, 10, 0, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?('delayed_failed_jobs_total{job_name="Object",service="service1"} 1'), "has failed job")
    assert(result.include?('delayed_jobs_total{job_name="Class",service="service1"} 1'), "has working job")
    assert(result.include?('delayed_job_duration_seconds{job_name="Class",service="service1"}'), "has duration")
    assert(result.include?("delayed_jobs_enqueued 10"), "has enqueued count")
    assert(result.include?("delayed_jobs_pending 0"), "has pending count")
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
