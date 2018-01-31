module PrometheusExporter::Instrumentation
  class Sidekiq

    def initialize(client: nil)
      @client = client || PrometheusExporter::Client.default
    end

    def call(worker, msg, queue)
      success = false
      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      result = yield
      success = true
      result
    ensure
      duration = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start

      @client.send_json(
        type: "sidekiq",
        name: worker.class.to_s,
        success: success,
        duration: duration
      )
    end
  end
end
