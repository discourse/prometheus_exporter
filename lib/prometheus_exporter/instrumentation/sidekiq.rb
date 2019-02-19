# frozen_string_literal: true

module PrometheusExporter::Instrumentation
  class Sidekiq

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
        retries_exhausted: retries_exhausted?(msg),
        duration: duration
      )
    end

    private

    def retries_exhausted?(msg)
      max_retries_or_bool = msg["retry"]
      return true unless max_retries_or_bool
      max_retries =
        if max_retries_or_bool.is_a?(Numeric)
          max_retries_or_bool
        else
          ::Sidekiq.options[:max_retries] || ::Sidekiq::JobRetry::DEFAULT_MAX_RETRY_ATTEMPTS
        end
      current_retry_index = msg["retry_count"] || 0
      current_retry_index + 1 >= max_retries
    end
  end
end
