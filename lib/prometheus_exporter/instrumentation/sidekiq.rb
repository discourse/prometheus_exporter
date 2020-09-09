# frozen_string_literal: true

require 'yaml'

module PrometheusExporter::Instrumentation
  JOB_WRAPPER_CLASS_NAME = 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper'
  DELAYED_CLASS_NAMES = [
    'Sidekiq::Extensions::DelayedClass',
    'Sidekiq::Extensions::DelayedModel',
    'Sidekiq::Extensions::DelayedMailer',
  ]

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
      @client.send_json(
        type: "sidekiq",
        name: get_name(worker, msg),
        success: success,
        shutdown: shutdown,
        duration: duration
      )
    end

    private

    def get_name(worker, msg)
      class_name = worker.class.to_s
      if class_name == JOB_WRAPPER_CLASS_NAME
        get_job_wrapper_name(msg)
      elsif DELAYED_CLASS_NAMES.include?(class_name)
        get_delayed_name(msg, class_name)
      else
        class_name
      end
    end

    def get_job_wrapper_name(msg)
      msg['wrapped']
    end

    def get_delayed_name(msg, class_name)
      # fallback to class_name since we're relying on the internal implementation
      # of the delayed extensions
      # https://github.com/mperham/sidekiq/blob/master/lib/sidekiq/extensions/class_methods.rb
      begin
        (target, method_name, _args) = YAML.load(msg['args'].first)
        "#{target.name}##{method_name}"
      rescue
        class_name
        raise
      end
    end
  end
end
