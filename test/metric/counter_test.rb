# frozen_string_literal: true

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

      text = <<~TEXT
        # HELP web_a_counter my amazing counter
        # TYPE web_a_counter counter
        web_a_counter 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
      Base.default_prefix = ''
    end

    it "can correctly increment counters with labels" do
      counter.observe(2, sam: "ham")
      counter.observe(1, sam: "ham", fam: "bam")
      counter.observe

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{sam="ham"} 2
        a_counter{sam="ham",fam="bam"} 1
        a_counter 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "can correctly increment" do
      counter.observe(1, sam: "ham")
      counter.increment({ sam: "ham" }, 2)

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{sam="ham"} 3
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "can correctly decrement" do
      counter.observe(5, sam: "ham")
      counter.decrement({ sam: "ham" }, 2)

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{sam="ham"} 3
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "can correctly log multiple increments" do

      counter.observe
      counter.observe
      counter.observe

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter 3
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "can correctly escape label names" do
      counter.observe(1, sam: "encoding \\ \\")
      counter.observe(1, sam: "encoding \" \"")
      counter.observe(1, sam: "encoding \n \n")

      # per spec: label_value can be any sequence of UTF-8 characters, but the backslash (\, double-quote ("}, and line feed (\n) characters have to be escaped as \\, \", and \n, respectively

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{sam="encoding \\\\ \\\\"} 1
        a_counter{sam="encoding \\" \\""} 1
        a_counter{sam="encoding \\n \\n"} 1
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "can correctly reset to a default value" do
      counter.observe(5, sam: "ham")
      counter.reset(sam: "ham")

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{sam="ham"} 0
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "can correctly reset to an explicit value" do
      counter.observe(5, sam: "ham")
      counter.reset({ sam: "ham" }, 2)

      text = <<~TEXT
        # HELP a_counter my amazing counter
        # TYPE a_counter counter
        a_counter{sam="ham"} 2
      TEXT

      assert_equal(counter.to_prometheus_text, text)
    end

    it "can correctly return data set" do
      counter.observe(5, sam: "ham")
      counter.observe(10, foo: "bar")

      assert_equal(counter.to_h, { sam: "ham" } => 5, { foo: "bar" } => 10)
    end
  end
end
