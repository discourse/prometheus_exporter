# frozen_string_literal: true

require_relative '../test_helper'
require 'prometheus_exporter/metric'

module PrometheusExporter::Metric
  describe Histogram do
    let :histogram do
      Histogram.new("a_histogram", "my amazing histogram")
    end

    before do
      Base.default_prefix = ''
    end

    it "can correctly gather a histogram" do
      histogram.observe(0.1)
      histogram.observe(0.2)
      histogram.observe(0.610001)
      histogram.observe(0.610001)
      histogram.observe(0.610001)
      histogram.observe(0.910001)
      histogram.observe(0.1)

      expected = <<~TEXT
        # HELP a_histogram my amazing histogram
        # TYPE a_histogram histogram
        a_histogram_bucket{le="0.005"} 0
        a_histogram_bucket{le="0.01"} 0
        a_histogram_bucket{le="0.025"} 0
        a_histogram_bucket{le="0.05"} 0
        a_histogram_bucket{le="0.1"} 2
        a_histogram_bucket{le="0.25"} 3
        a_histogram_bucket{le="0.5"} 3
        a_histogram_bucket{le="1"} 7
        a_histogram_bucket{le="2.5"} 7
        a_histogram_bucket{le="5.0"} 7
        a_histogram_bucket{le="10.0"} 7
        a_histogram_bucket{le="+Inf"} 7
        a_histogram_count 7
        a_histogram_sum 3.1400040000000002
      TEXT

      assert_equal(histogram.to_prometheus_text, expected)
    end

    it "can correctly gather a histogram over multiple labels" do

      histogram.observe(0.1, nil)
      histogram.observe(0.2)
      histogram.observe(0.610001)
      histogram.observe(0.610001)

      histogram.observe(0.1, name: "bob", family: "skywalker")
      histogram.observe(0.7, name: "bob", family: "skywalker")
      histogram.observe(0.99, name: "bob", family: "skywalker")

      expected = <<~TEXT
        # HELP a_histogram my amazing histogram
        # TYPE a_histogram histogram
        a_histogram_bucket{le="0.005"} 0
        a_histogram_bucket{le="0.01"} 0
        a_histogram_bucket{le="0.025"} 0
        a_histogram_bucket{le="0.05"} 0
        a_histogram_bucket{le="0.1"} 1
        a_histogram_bucket{le="0.25"} 2
        a_histogram_bucket{le="0.5"} 2
        a_histogram_bucket{le="1"} 4
        a_histogram_bucket{le="2.5"} 4
        a_histogram_bucket{le="5.0"} 4
        a_histogram_bucket{le="10.0"} 4
        a_histogram_bucket{le="+Inf"} 4
        a_histogram_count 4
        a_histogram_sum 1.520002
        a_histogram_bucket{name="bob",family="skywalker",le="0.005"} 0
        a_histogram_bucket{name="bob",family="skywalker",le="0.01"} 0
        a_histogram_bucket{name="bob",family="skywalker",le="0.025"} 0
        a_histogram_bucket{name="bob",family="skywalker",le="0.05"} 0
        a_histogram_bucket{name="bob",family="skywalker",le="0.1"} 1
        a_histogram_bucket{name="bob",family="skywalker",le="0.25"} 1
        a_histogram_bucket{name="bob",family="skywalker",le="0.5"} 1
        a_histogram_bucket{name="bob",family="skywalker",le="1"} 3
        a_histogram_bucket{name="bob",family="skywalker",le="2.5"} 3
        a_histogram_bucket{name="bob",family="skywalker",le="5.0"} 3
        a_histogram_bucket{name="bob",family="skywalker",le="10.0"} 3
        a_histogram_bucket{name="bob",family="skywalker",le="+Inf"} 3
        a_histogram_count{name="bob",family="skywalker"} 3
        a_histogram_sum{name="bob",family="skywalker"} 1.79
      TEXT

      assert_equal(histogram.to_prometheus_text, expected)
    end

    it "can correctly gather a histogram using custom buckets" do
      histogram = Histogram.new("a_histogram", "my amazing histogram", buckets: [2, 1, 3])

      histogram.observe(0.5)
      histogram.observe(1.5)
      histogram.observe(4)
      histogram.observe(2, name: "gargamel")

      expected = <<~TEXT
        # HELP a_histogram my amazing histogram
        # TYPE a_histogram histogram
        a_histogram_bucket{le="1"} 1
        a_histogram_bucket{le="2"} 2
        a_histogram_bucket{le="3"} 2
        a_histogram_bucket{le="+Inf"} 3
        a_histogram_count 3
        a_histogram_sum 6.0
        a_histogram_bucket{name="gargamel",le="1"} 0
        a_histogram_bucket{name="gargamel",le="2"} 1
        a_histogram_bucket{name="gargamel",le="3"} 1
        a_histogram_bucket{name="gargamel",le="+Inf"} 1
        a_histogram_count{name="gargamel"} 1
        a_histogram_sum{name="gargamel"} 2.0
      TEXT

      assert_equal(histogram.to_prometheus_text, expected)
    end

    it "can correctly return data set" do
      histogram.observe(0.1, name: "bob", family: "skywalker")
      histogram.observe(0.7, name: "bob", family: "skywalker")
      histogram.observe(0.99, name: "bob", family: "skywalker")

      assert_equal(histogram.to_h, { name: "bob", family: "skywalker" } => { "count" => 3, "sum" => 1.79 })
    end

    it "can correctly remove histograms" do
      histogram.observe(0.1, name: "bob", family: "skywalker")
      histogram.observe(0.7, name: "bob", family: "skywalker")
      histogram.observe(0.99, name: "bob", family: "skywalker")

      histogram.observe(0.6, name: "gandalf", family: "skywalker")

      histogram.remove(name: "gandalf", family: "skywalker")
      histogram.remove(name: "jane", family: "skywalker")

      assert_equal(histogram.to_h, { name: "bob", family: "skywalker" } => { "count" => 3, "sum" => 1.79 })
    end

    it 'supports default buckets' do
      assert_equal(Histogram::DEFAULT_BUCKETS, [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5.0, 10.0])
      assert_equal(Histogram::DEFAULT_BUCKETS, Histogram.default_buckets)
    end

    it 'allows to change default buckets' do
      custom_buckets = [0.005, 0.1, 1, 2, 5, 10]
      Histogram.default_buckets = custom_buckets

      assert_equal(Histogram.default_buckets, custom_buckets)

      Histogram.default_buckets = Histogram::DEFAULT_BUCKETS
    end

    it 'uses the default buckets for instance' do
      assert_equal(histogram.buckets, Histogram::DEFAULT_BUCKETS)
    end

    it 'uses the the custom default buckets for instance' do
      custom_buckets = [0.005, 0.1, 1, 2, 5, 10]
      Histogram.default_buckets = custom_buckets

      assert_equal(histogram.buckets, custom_buckets)

      Histogram.default_buckets = Histogram::DEFAULT_BUCKETS
    end

    it 'uses the specified buckets' do
      buckets = [0.1, 0.2, 0.3]
      histogram = Histogram.new('test_bucktets', 'I have specified buckets', buckets: buckets)

      assert_equal(histogram.buckets, buckets)
    end
  end
end
