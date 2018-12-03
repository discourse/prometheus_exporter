require 'test_helper'
require 'prometheus_exporter/metric'

module PrometheusExporter::Metric
  describe Base do
    let :counter do
      Counter.new("a_counter", "my amazing counter")
    end

    after do
      Base.default_prefix = ''
      Base.default_labels = {}
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
  end
end
