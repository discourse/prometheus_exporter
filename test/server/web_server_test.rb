require 'test_helper'
require 'prometheus_exporter/server'
require 'prometheus_exporter/client'
require 'net/http'

class DemoCollector

  def initialize
    @gauge = PrometheusExporter::Metric::Gauge.new "memory", "amount of memory"
  end

  def process(str)
    obj = JSON.parse(str)
    if obj["type"] == "mem metric"
      @gauge.observe(obj["value"])
    end
  end

  def prometheus_metrics_text
    @gauge.to_prometheus_text
  end

end

class PrometheusExporterTest < Minitest::Test

  def setup
    PrometheusExporter::Metric::Base.default_prefix = ''
  end

  def find_free_port
    port = 12437
    while port < 13_000
      begin
        TCPSocket.new("localhost", port).close
        port += 1
      rescue Errno::ECONNREFUSED
        break
      end
    end
    port
  end

  def test_it_can_collect_with_and_without_oj
    port = find_free_port

    server = PrometheusExporter::Server::WebServer.new port: port
    collector = server.collector
    server.start

    client1 = PrometheusExporter::Client.new port: port, thread_sleep: 0.001, json_serializer: :oj
    client2 = PrometheusExporter::Client.new port: port, thread_sleep: 0.001, json_serializer: :json
    client3 = PrometheusExporter::Client.new port: port, thread_sleep: 0.001

    gauge1 = client1.register(:gauge, "my_gauge1", "some gauge")
    gauge2 = client2.register(:gauge, "my_gauge2", "some gauge")
    gauge3 = client3.register(:gauge, "my_gauge3", "some gauge")

    gauge1.observe(7)
    gauge2.observe(8)
    gauge3.observe(9)

    text = nil

    TestHelper.wait_for(2) do
      text = collector.prometheus_metrics_text
      text =~ /7/ && text =~ /8/ && text =~ /9/
    end

    assert(text =~ /7/)
    assert(text =~ /8/)
    assert(text =~ /9/)

  end

  def test_it_can_collect_over_ipv6
    port = find_free_port

    server = PrometheusExporter::Server::WebServer.new port: port
    collector = server.collector
    server.start

    client = PrometheusExporter::Client.new host: "::1", port: port, thread_sleep: 0.001
    gauge = client.register(:gauge, "my_gauge", "some gauge")
    gauge.observe(99)

    TestHelper.wait_for(2) do
      server.collector.prometheus_metrics_text =~ /99/
    end

    expected = <<-TEXT
# HELP my_gauge some gauge
# TYPE my_gauge gauge
my_gauge 99
    TEXT
    assert_equal(expected, collector.prometheus_metrics_text)
  ensure
    client.stop rescue nil
    server.stop rescue nil
  end

  def test_it_can_collect_metrics_from_standard
    port = find_free_port

    server = PrometheusExporter::Server::WebServer.new port: port
    collector = server.collector
    server.start

    client = PrometheusExporter::Client.new host: "localhost", port: port, thread_sleep: 0.001

    gauge = client.register(:gauge, "my_gauge", "some gauge")
    counter = client.register(:counter, "my_counter", "some counter")

    gauge.observe(2, abcd: 1)
    counter.observe(1)
    counter.observe(3)
    gauge.observe(92, abcd: 1)

    TestHelper.wait_for(2) do
      server.collector.prometheus_metrics_text =~ /92/
    end

    expected = <<-TEXT
# HELP my_gauge some gauge
# TYPE my_gauge gauge
my_gauge{abcd="1"} 92

# HELP my_counter some counter
# TYPE my_counter counter
my_counter 4
    TEXT
    assert_equal(expected, collector.prometheus_metrics_text)

  ensure
    client.stop rescue nil
    server.stop rescue nil
  end

  def test_it_can_collect_metrics_from_custom
    collector = DemoCollector.new
    port = find_free_port

    server = PrometheusExporter::Server::WebServer.new port: port, collector: collector
    server.start

    client = PrometheusExporter::Client.new host: "localhost", port: port, thread_sleep: 0.001
    client.send_json "type" => "mem metric", "value" => 150
    client.send_json "type" => "mem metric", "value" => 199

    TestHelper.wait_for(2) do
      collector.prometheus_metrics_text =~ /199/
    end

    assert_match(/199/, collector.prometheus_metrics_text)

    body = nil

    Net::HTTP.new("localhost", port).start do |http|
      request = Net::HTTP::Get.new "/metrics"

      http.request(request) do |response|
        assert_equal(["gzip"], response.to_hash["content-encoding"])
        body = response.body
      end
    end
    assert_match(/199/, body)

    one_minute = Time.now + 60
    Time.stub(:now, one_minute) do
      client.send_json "type" => "mem metric", "value" => 200.1

      TestHelper.wait_for(2) do
        collector.prometheus_metrics_text =~ /200.1/
      end

      assert_match(/200.1/, collector.prometheus_metrics_text)
    end

  ensure
    client.stop rescue nil
    server.stop rescue nil
  end
end
