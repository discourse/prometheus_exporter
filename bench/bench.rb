# frozen_string_literal: true

require_relative "../lib/prometheus_exporter"
require_relative "../lib/prometheus_exporter/client"
require_relative "../lib/prometheus_exporter/server"

class Collector
  def initialize
    @count = 0
    @mutex = Mutex.new
    @condition = ConditionVariable.new
  end

  def process(message)
    JSON.parse(message)
    @mutex.synchronize do
      @count += 1
      @condition.broadcast
    end
  end

  def prometheus_metrics_text
    ""
  end

  def wait_for(target, timeout: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    @mutex.synchronize do
      while @count < target
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise "timed out after receiving #{@count}/#{target} records" if remaining <= 0

        @condition.wait(@mutex, remaining)
      end
    end
  end
end

records = Integer(ENV.fetch("RECORDS", "10000"), 10)
runs = Integer(ENV.fetch("RUNS", "3"), 10)
collector = Collector.new
server = PrometheusExporter::Server::WebServer.new(port: 0, bind: "127.0.0.1", collector: collector)
client = nil

begin
  server.start
  client =
    PrometheusExporter::Client.new(
      host: "127.0.0.1",
      port: server.port,
      max_queue_size: records * 2,
      max_queue_bytes: records * 1024,
      thread_sleep: 0.001,
    )
  puts "Puma #{Puma::Const::PUMA_VERSION}; #{records} records/run; #{runs} runs"

  runs.times do |run|
    target = records * (run + 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    records.times { client.send_json(hello: "world") }
    enqueued = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # process_queue serializes behind any active worker and returns only after
    # every dequeued request has received its final HTTP response.
    client.process_queue
    collector.wait_for(target)
    acknowledged = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = acknowledged - started

    puts format(
           "run %d: enqueue %.4fs; acknowledged %.4fs (%d records/s)",
           run + 1,
           enqueued - started,
           elapsed,
           records / elapsed,
         )
  end
ensure
  client&.stop(wait_timeout_seconds: 2)
  server&.stop
end
