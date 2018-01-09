require 'test_helper'
require 'prometheus_exporter/metric'

module PrometheusExporter::Metric
  describe Gauge do
    let :gauge do
      Gauge.new("a_gauge", "my amazing gauge")
    end

    before do
      Base.default_prefix = ''
    end

    it "can serialize and deserialize correctly" do
      gauge.observe(2, test: "a")
      gauge.observe(2, a: "b", c: "d")
      gauge.observe(1)

      old_text = gauge.to_prometheus_text

      copy = Base.from_json(gauge.to_json)

      new_text = copy.to_prometheus_text

      assert_equal(new_text, old_text)

      copy.observe(3, test: "a")

      expected = <<~TEXT
        # HELP a_gauge my amazing gauge
        # TYPE a_gauge gauge
        a_gauge{test="a"} 3
        a_gauge{a="b",c="d"} 2
        a_gauge 1
      TEXT

      assert_equal(copy.to_prometheus_text, expected)

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
    end

    it "can correctly increment gauges with labels" do
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
  end
end
