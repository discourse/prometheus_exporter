# frozen_string_literal: true

module PrometheusExporter::Instrumentation
  class Sidekiq
    def self.death_handler
      -> (job, ex) do
        job_is_fire_and_forget = job["retry"] == false

        unless job_is_fire_and_forget
          PrometheusExporter::Client.default.send_json(
            type: "sidekiq",
            name: job["class"],
            dead: true,
          )
        end
      end
    end

    def initialize(client: nil)
      @client = client || PrometheusExporter::Client.default
    end

    def call(worker, msg, queue)
      success = false
      shutdown = false
      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      result = yield
      success = true
      result
    rescue ::Sidekiq::Shutdown => e
      shutdown = true
      raise e
    ensure
      duration = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start
      class_name = worker.class.to_s == 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper' ?
                     msg['wrapped'] : worker.class.to_s
      @client.send_json(
        type: "sidekiq",
        name: class_name,
        success: success,
        shutdown: shutdown,
        duration: duration
      )
    end
  end
end
