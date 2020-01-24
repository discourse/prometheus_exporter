# frozen_string_literal: true

module PrometheusExporter::Instrumentation
  class Shoryuken

    def initialize(client: nil)
      @client = client || PrometheusExporter::Client.default
    end

    def call(worker, queue, msg, body)
      success = false
      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      result = yield
      success = true
      result
    rescue ::Shoryuken::Shutdown => e
      shutdown = true
      raise e
    ensure
      duration = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start
      @client.send_json(
          type: "shoryuken",
          queue: queue,
          name: worker.class.name,
          success: success,
          shutdown: shutdown,
          duration: duration
      )
    end
  end
end
