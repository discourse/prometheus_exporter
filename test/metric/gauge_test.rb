# frozen_string_literal: true

require_relative '../test_helper'
require 'prometheus_exporter/metric'

module PrometheusExporter::Metric
  describe Gauge do
    let :gauge do
      Gauge.new("a_gauge", "my amazing gauge")
    end

    let :gauge_with_total_suffix do
      Gauge.new("a_gauge_total", "my amazing gauge")
    end

    before do
      Base.default_prefix = ''
    end

    it "should not allow observe to corrupt data" do
      assert_raises do
        gauge.observe("hello")
      end

      # going to special case nil here instead of adding a new API
      # observing nil should set to nothing
      # this is a slight difference to official API which would raise
      # on non numeric, however it provides a bit more flexibility
      # and allows us to remove metrics if we wish
      gauge.observe(100)
      gauge.observe(nil)
      gauge.observe(nil, a: "thing")

      text = <<~TEXT
        # HELP a_gauge my amazing gauge
        # TYPE a_gauge gauge

      TEXT

      assert_equal(gauge.to_prometheus_text, text)
    end

    it "supports a dynamic prefix" do
      Base.default_prefix = 'web_'
      gauge.observe(400.11)

      text = <<~TEXT
        # HELP web_a_gauge my amazing gauge
        # TYPE web_a_gauge gauge
        web_a_gauge 400.11
      TEXT

      assert_equal(gauge.to_prometheus_text, text)

      Base.default_prefix = ''
    end

    it "can correctly set gauges with labels" do
      gauge.observe(100.5, sam: "ham")
      gauge.observe(5, sam: "ham", fam: "bam")
      gauge.observe(400.11)

      text = <<~TEXT
        # HELP a_gauge my amazing gauge
        # TYPE a_gauge gauge
        a_gauge{sam="ham"} 100.5
        a_gauge{sam="ham",fam="bam"} 5
        a_gauge 400.11
      TEXT

      assert_equal(gauge.to_prometheus_text, text)
    end

    it "can correctly reset on change" do

      gauge.observe(10)
      gauge.observe(11)

      text = <<~TEXT
        # HELP a_gauge my amazing gauge
        # TYPE a_gauge gauge
        a_gauge 11
      TEXT

      assert_equal(gauge.to_prometheus_text, text)
    end

    it "can use the set on alias" do

      gauge.set(10)
      gauge.set(11)

      text = <<~TEXT
        # HELP a_gauge my amazing gauge
        # TYPE a_gauge gauge
        a_gauge 11
      TEXT

      assert_equal(gauge.to_prometheus_text, text)
    end

    it "can correctly reset on change with labels" do
      gauge.observe(1, sam: "ham")
      gauge.observe(2, sam: "ham")

      text = <<~TEXT
        # HELP a_gauge my amazing gauge
        # TYPE a_gauge gauge
        a_gauge{sam="ham"} 2
      TEXT

      assert_equal(gauge.to_prometheus_text, text)
    end

    it "can correctly increment" do
      gauge.observe(1, sam: "ham")
      gauge.increment({ sam: "ham" }, 2)

      text = <<~TEXT
        # HELP a_gauge my amazing gauge
        # TYPE a_gauge gauge
        a_gauge{sam="ham"} 3
      TEXT

      assert_equal(gauge.to_prometheus_text, text)
    end

    it "can correctly decrement" do
      gauge.observe(5, sam: "ham")
      gauge.decrement({ sam: "ham" }, 2)

      text = <<~TEXT
        # HELP a_gauge my amazing gauge
        # TYPE a_gauge gauge
        a_gauge{sam="ham"} 3
      TEXT

      assert_equal(gauge.to_prometheus_text, text)
    end

    it "can correctly remove metrics" do
      gauge.observe(5, sam: "ham")
      gauge.observe(10, foo: "bar")
      gauge.remove(sam: "ham")
      gauge.remove(bam: "ham")

      assert_equal(gauge.to_h, { foo: "bar" } => 10)
    end

    it "can correctly return data set" do
      gauge.observe(5, sam: "ham")
      gauge.observe(10, foo: "bar")

      assert_equal(gauge.to_h, { sam: "ham" } => 5, { foo: "bar" } => 10)
    end

    it "should not allow to create new instance with _total suffix" do
      assert_raises ArgumentError do
        gauge_with_total_suffix
      end
    end
  end
end
