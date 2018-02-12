module PrometheusExporter::Instrumentation
  class DelayedJob

    class << self
      def register_plugin(client: nil)
        instrumenter = self.new(client: client)
        return unless defined?(Delayed::Plugin)

        plugin = Class.new(Delayed::Plugin) do
          callbacks do |lifecycle|
            lifecycle.around(:invoke_job) do |job, *args, &block|
              instrumenter.call(job, *args, &block)
            end
          end
        end

        Delayed::Worker.plugins << plugin
      end
    end

    def initialize(client: nil)
      @client = client || PrometheusExporter::Client.default
    end

    def call(job, *args, &block)
      success = false
      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      result = block.call(job, *args)
      success = true
      result
    ensure
      duration = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start

      @client.send_json(
        type: "delayed_job",
        name: YAML.load(job.handler).job_data["job_class"].to_s,
        success: success,
        duration: duration
      )
    end
  end
end
