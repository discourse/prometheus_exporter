require 'test_helper'
require 'prometheus_exporter/metric'

module PrometheusExporter::Metric
  describe Counter do
    let :counter do
      Counter.new("a_counter", "my amazing counter")
    end

    before do
      Base.default_prefix = ''
    end

    it "supports a dynamic prefix" do
      Base.default_prefix = 'web_'
      counter.observe

      text = <<-TEXT
# HELP web_a_counter my amazing counter
# TYPE web_a_counter counter
web_a_counter 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "can correctly increment counters with labels" do
      counter.observe(2, sam: "ham")
      counter.observe(1, sam: "ham", fam: "bam")
      counter.observe

      text = <<-TEXT
# HELP a_counter my amazing counter
# TYPE a_counter counter
a_counter{sam="ham"} 2
a_counter{sam="ham",fam="bam"} 1
a_counter 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "can correctly log multiple increments" do

      counter.observe
      counter.observe
      counter.observe

      text = <<-TEXT
# HELP a_counter my amazing counter
# TYPE a_counter counter
a_counter 3
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end
  end
end
