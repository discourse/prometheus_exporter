# frozen_string_literal: true

require 'test_helper'
require 'prometheus_exporter/metric'

module PrometheusExporter::Metric
  describe Base do
    let :counter do
      Counter.new("a_counter", "my amazing counter")
    end

    before  do
      Base.default_prefix = ''
      Base.default_labels = {}
      Base.default_aggregation = nil
    end

    after do
      Base.default_prefix = ''
      Base.default_aggregation = nil
    end

    it "supports a dynamic prefix" do
      Base.default_prefix = 'web_'
      counter.observe

      text = <<~TEXT
        # HELP web_a_counter my amazing counter
        # TYPE web_a_counter counter
        web_a_counter 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "supports default labels" do
      Base.default_labels = { foo: "bar" }

      counter.observe(2, baz: "bar")
      counter.observe

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{baz="bar",foo="bar"} 2
        a_counter{foo="bar"} 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "supports reset! for Gauge" do

      gauge = Gauge.new("test", "test")

      gauge.observe(999)
      gauge.observe(100, a: "a")
      gauge.reset!

      text = <<~TEXT
        # HELP test test
        # TYPE test gauge
      TEXT

      assert_equal(gauge.to_prometheus_text.strip, text.strip)
    end

    it "supports reset! for Counter" do

      counter = Counter.new("test", "test")

      counter.observe(999)
      counter.observe(100, a: "a")
      counter.reset!

      text = <<~TEXT
        # HELP test test
        # TYPE test counter
      TEXT

      assert_equal(counter.to_prometheus_text.strip, text.strip)
    end

    it "supports reset! for Histogram" do

      histogram = Histogram.new("test", "test")

      histogram.observe(999)
      histogram.observe(100, a: "a")
      histogram.reset!

      text = <<~TEXT
        # HELP test test
        # TYPE test histogram
      TEXT

      assert_equal(histogram.to_prometheus_text.strip, text.strip)
    end

    it "supports reset! for Summary" do

      summary = Summary.new("test", "test")

      summary.observe(999)
      summary.observe(100, a: "a")
      summary.reset!

      text = <<~TEXT
        # HELP test test
        # TYPE test summary
      TEXT

      assert_equal(summary.to_prometheus_text.strip, text.strip)
    end

    it "creates a summary by default" do
      aggregation = Base.default_aggregation.new("test", "test")

      text = <<~TEXT
        # HELP test test
        # TYPE test summary
      TEXT

      assert_equal(aggregation.to_prometheus_text.strip, text.strip)
    end

    it "creates a histogram when configured" do
      Base.default_aggregation = Histogram
      aggregation = Base.default_aggregation.new("test", "test")

      text = <<~TEXT
        # HELP test test
        # TYPE test histogram
      TEXT

      assert_equal(aggregation.to_prometheus_text.strip, text.strip)
    end
  end
end
