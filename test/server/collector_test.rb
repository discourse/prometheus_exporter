require 'test_helper'
require 'mini_racer'
require 'prometheus_exporter/server'
require 'prometheus_exporter/instrumentation'

class PrometheusCollectorTest < Minitest::Test

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
  end

  class PipedClient
    def initialize(collector)
      @collector = collector
    end

    def send_json(obj)
      @collector.process(obj.to_json)
    end
  end

  def test_register_metric
    collector = PrometheusExporter::Server::Collector.new
    metric = PrometheusExporter::Metric::Gauge.new("amazing", "amount of amazing")
    collector.register_metric(metric)
    metric.observe(77)
    metric.observe(2, red: "alert")
    text = <<-TXT
# HELP amazing amount of amazing
# TYPE amazing gauge
amazing 77
amazing{red="alert"} 2
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

    assert(result.include?("sidekiq_failed_job_count{job_name=\"FalseClass\"} 1"), "has failed job")

    assert(result.include?("sidekiq_job_count{job_name=\"String\"} 1"), "has working job")
    assert(result.include?("sidekiq_job_duration_seconds"), "has duration")
  end

  def test_it_can_collect_process_metrics
    # make some mini racer data
    ctx = MiniRacer::Context.new
    ctx.eval("1")

    collector = PrometheusExporter::Server::Collector.new

    process_instrumentation = PrometheusExporter::Instrumentation::Process.new(:web)
    collected = process_instrumentation.collect

    collector.process(collected.to_json)

    text = collector.prometheus_metrics_text

    v8_str = "v8_heap_count{pid=\"#{collected[:pid]}\",type=\"web\"} #{collected[:v8_heap_count]}"
    assert(text.include?(v8_str), "must include v8 metric")
    assert(text.include?("minor_gc_count"), "must include counters")
  end

  def test_it_can_collect_delayed_job_metrics
    collector = PrometheusExporter::Server::Collector.new
    client = PipedClient.new(collector)

    instrument = PrometheusExporter::Instrumentation::DelayedJob.new(client: client)

    job = Minitest::Mock.new
    job.expect(:handler, "job_class: Class")

    instrument.call(job, nil, "default") do
      # nothing
    end

    failed_job = Minitest::Mock.new
    failed_job.expect(:handler, "job_class: Object")

    begin
      instrument.call(failed_job, nil, "default") do
        boom
      end
    rescue
    end

    result = collector.prometheus_metrics_text

    assert(result.include?("delayed_failed_job_count{job_name=\"Object\"} 1"), "has failed job")
    assert(result.include?("delayed_job_count{job_name=\"Class\"} 1"), "has working job")
    assert(result.include?("delayed_job_duration_seconds"), "has duration")
    job.verify
    failed_job.verify
  end
end
