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

        worker_class = Object.const_get(job["class"])
        worker_custom_labels = self.get_worker_custom_labels(worker_class, job)

        unless job_is_fire_and_forget
          PrometheusExporter::Client.default.send_json(
            type: "sidekiq",
            name: get_name(job["class"], job),
            dead: true,
            custom_labels: worker_custom_labels
          )
        end
      end
    end

    def self.get_worker_custom_labels(worker_class, msg)
      return {} unless worker_class.respond_to?(:custom_labels)

      # TODO remove when version 3.0.0 is released
      method_arity = worker_class.method(:custom_labels).arity

      if method_arity > 0
        worker_class.custom_labels(msg)
      else
        worker_class.custom_labels
      end
    end

    def initialize(options = { client: nil })
      @client = options.fetch(:client, nil) || PrometheusExporter::Client.default
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
        name: self.class.get_name(worker.class.to_s, msg),
        queue: queue,
        success: success,
        shutdown: shutdown,
        duration: duration,
        custom_labels: self.class.get_worker_custom_labels(worker.class, msg)
      )
    end

    private

    def self.get_name(class_name, msg)
      if class_name == JOB_WRAPPER_CLASS_NAME
        get_job_wrapper_name(msg)
      elsif DELAYED_CLASS_NAMES.include?(class_name)
        get_delayed_name(msg, class_name)
      else
        class_name
      end
    end

    def self.get_job_wrapper_name(msg)
      msg['wrapped']
    end

    def self.get_delayed_name(msg, class_name)
      begin
        # fallback to class_name since we're relying on the internal implementation
        # of the delayed extensions
        # https://github.com/mperham/sidekiq/blob/master/lib/sidekiq/extensions/class_methods.rb
        (target, method_name, _args) = YAML.load(msg['args'].first) # rubocop:disable Security/YAMLLoad
        if target.class == Class
          "#{target.name}##{method_name}"
        else
          "#{target.class.name}##{method_name}"
        end
      rescue Psych::DisallowedClass, ArgumentError
        parsed = Psych.parse(msg['args'].first)
        children = parsed.root.children
        target = (children[0].value || children[0].tag).sub('!', '')
        method_name = (children[1].value || children[1].tag).sub(':', '')

        if target && method_name
          "#{target}##{method_name}"
        else
          class_name
        end
      end
    rescue
      class_name
    end
  end
end
