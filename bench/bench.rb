require_relative '../lib/prometheus_exporter'
require_relative '../lib/prometheus_exporter/client'
require_relative '../lib/prometheus_exporter/server'
require 'oj'

# test how long it takes a custom collector to process 10k messages

class Collector
  def initialize(done)
    @i = 0
    @done = done
  end

  def process(message)
    _parsed = JSON.parse(message)
    p @i if @i % 100 == 0
    @done.call if (@i += 1) == 10_000
  end

  def prometheus_metrics_text
  end
end

@start = nil
done = lambda do
  puts "Elapsed for 10k messages is #{Time.now - @start}"
end

collector = Collector.new(done)
server = PrometheusExporter::Server::WebServer.new port: 12349, collector: collector
server.start
client = PrometheusExporter::Client.new port: 12349, max_queue_size: 20_000

@start = Time.now
10_000.times { client.send_json(hello: "world") }

sleep
