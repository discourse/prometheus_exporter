# frozen_string_literal: true

module PrometheusExporter::Instrumentation
  class DelayedJob
    JOB_CLASS_REGEXP = %r{job_class: (\w+:{0,2})+}.freeze

    class << self
      def register_plugin(client: nil)
        instrumenter = self.new(client: client)
        return unless defined?(Delayed::Plugin)

        plugin = Class.new(Delayed::Plugin) do
          callbacks do |lifecycle|
            lifecycle.around(:invoke_job) do |job, *args, &block|
              max_attempts = Delayed::Worker.max_attempts
              enqueued_count = Delayed::Job.where(queue: job.queue).count
              pending_count = Delayed::Job.where(attempts: 0, locked_at: nil, queue: job.queue).count
              instrumenter.call(job, max_attempts, enqueued_count, pending_count, *args, &block)
            end
          end
        end

        Delayed::Worker.plugins << plugin
      end
    end

    def initialize(client: nil)
      @client = client || PrometheusExporter::Client.default
    end

    def call(job, max_attempts, enqueued_count, pending_count, *args, &block)
      success = false
      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      attempts = job.attempts + 1 # Increment because we're adding the current attempt
      result = block.call(job, *args)
      success = true
      result
    ensure
      duration = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start

      @client.send_json(
        type: "delayed_job",
        name: job.handler.to_s.match(JOB_CLASS_REGEXP).to_a[1].to_s,
        queue_name: job.queue,
        success: success,
        duration: duration,
        attempts: attempts,
        max_attempts: max_attempts,
        enqueued: enqueued_count,
        pending: pending_count
      )
    end
  end
end
