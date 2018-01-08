require 'test_helper'
require 'prometheus_exporter/server'
require 'prometheus_exporter/metric'
require 'prometheus_exporter/client'
require 'net/http'

class DemoCollector

  def initialize
    @gauge = PrometheusExporter::Metric::Gauge.new "memory", "amount of memory"
  end

  def process(obj)
    if obj["type"] == "mem metric"
      @gauge.observe(obj["value"])
    end
  end

  def prometheus_metrics_text
    @gauge.to_prometheus_text
  end

end


class PrometheusExporterTest < Minitest::Test

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

  def test_it_can_collect_metrics
    collector = DemoCollector.new
    port = find_free_port

    server = PrometheusExporter::Server::WebServer.new port: port, collector: collector
    server.start

    client = PrometheusExporter::Client.new host: "localhost", port: port, thread_sleep: 0.001
    client.send "type" => "mem metric", "value" => 150
    client.send "type" => "mem metric", "value" => 199

    TestHelper.wait_for(2) do
      collector.prometheus_metrics_text =~ /199/
    end

    assert_match(/199/, collector.prometheus_metrics_text)

    body = Net::HTTP.get(URI("http://localhost:#{port}/metrics"))
    assert_match(/199/, body)

    one_minute = Time.now + 60
    Time.stub(:now, one_minute) do
      client.send "type" => "mem metric", "value" => 200.1

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
