# frozen_string_literal: true

module PrometheusExporter::Instrumentation
  class Hutch
    def initialize(klass)
      @klass = klass
      @client = PrometheusExporter::Client.default
    end

    def handle(message)
      success = false
      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      result = @klass.process(message)
      success = true
      result
    ensure
      duration = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start
      @client.send_json(
        type: "hutch",
        name: @klass.class.to_s,
        success: success,
        duration: duration
      )
    end
  end
end
