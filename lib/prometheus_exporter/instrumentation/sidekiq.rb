# frozen_string_literal: true

module PrometheusExporter::Instrumentation
  class Sidekiq
    def self.set_death_handler_once(client)
      return unless const_defined?("Sidekiq")
      unless @death_handler_set
        ::Sidekiq.configure_server do |config|
          config.death_handlers << -> (job, ex) do
            client.send_json(
              type: "sidekiq",
              name: job["class"],
              dead: true,
            )
          end
        end
        @death_handler_set = true
      end
    end

    def initialize(client: nil)
      @client = client || PrometheusExporter::Client.default
      self.class.set_death_handler_once(@client)
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
