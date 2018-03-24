require 'test_helper'
require 'prometheus_exporter/metric'

module PrometheusExporter::Metric
  describe Summary do
    let :summary do
      Summary.new("a_summary", "my amazing summary")
    end

    before do
      Base.default_prefix = ''
    end

    it "can correctly gather a summary over multiple labels" do

      summary.observe(0.1, nil)
      summary.observe(0.2)
      summary.observe(0.610001)
      summary.observe(0.610001)

      summary.observe(0.1, name: "bob", family: "skywalker")
      summary.observe(0.7, name: "bob", family: "skywalker")
      summary.observe(0.99, name: "bob", family: "skywalker")

      expected = <<-TEXT
# HELP a_summary my amazing summary
# TYPE a_summary summary
a_summary{quantile="0.99"} 0.610001
a_summary{quantile="0.9"} 0.610001
a_summary{quantile="0.5"} 0.2
a_summary{quantile="0.1"} 0.1
a_summary{quantile="0.01"} 0.1
a_summary_sum 1.520002
a_summary_count 4
a_summary{name="bob",family="skywalker",quantile="0.99"} 0.99
a_summary{name="bob",family="skywalker",quantile="0.9"} 0.99
a_summary{name="bob",family="skywalker",quantile="0.5"} 0.7
a_summary{name="bob",family="skywalker",quantile="0.1"} 0.1
a_summary{name="bob",family="skywalker",quantile="0.01"} 0.1
a_summary_sum{name="bob",family="skywalker"} 1.79
a_summary_count{name="bob",family="skywalker"} 3
      TEXT

      assert_equal(summary.to_prometheus_text, expected)
    end

    it "can correctly gather a summary" do
      summary.observe(0.1)
      summary.observe(0.2)
      summary.observe(0.610001)
      summary.observe(0.610001)
      summary.observe(0.610001)
      summary.observe(0.910001)
      summary.observe(0.1)

      expected = <<-TEXT
# HELP a_summary my amazing summary
# TYPE a_summary summary
a_summary{quantile="0.99"} 0.910001
a_summary{quantile="0.9"} 0.910001
a_summary{quantile="0.5"} 0.610001
a_summary{quantile="0.1"} 0.1
a_summary{quantile="0.01"} 0.1
a_summary_sum 3.1400040000000002
a_summary_count 7
      TEXT

      assert_equal(summary.to_prometheus_text, expected)
    end

    it "can correctly rotate quantiles" do

      Process.stub(:clock_gettime, 1.0) do
        summary.observe(0.1)
        summary.observe(0.2)
        summary.observe(0.6)
      end

      Process.stub(:clock_gettime, 1.0 + Summary::ROTATE_AGE + 1.0) do
        summary.observe(300)
      end

      Process.stub(:clock_gettime, 1.0 + (Summary::ROTATE_AGE * 2) + 1.1) do
        summary.observe(100)
        summary.observe(200)
        summary.observe(300)

        expected = <<-TEXT
# HELP a_summary my amazing summary
# TYPE a_summary summary
a_summary{quantile="0.99"} 300.0
a_summary{quantile="0.9"} 300.0
a_summary{quantile="0.5"} 200.0
a_summary{quantile="0.1"} 100.0
a_summary{quantile="0.01"} 100.0
a_summary_sum 900.9
a_summary_count 7
        TEXT

        assert_equal(summary.to_prometheus_text, expected)
      end
    end

  end
end
