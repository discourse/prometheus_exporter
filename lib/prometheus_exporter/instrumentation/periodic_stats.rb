# frozen_string_literal: true

module PrometheusExporter::Instrumentation
  class PeriodicStats

    def self.start(*args, frequency:, client: nil, **kwargs)
      client ||= PrometheusExporter::Client.default

      if !(Numeric === frequency)
        raise ArgumentError.new("Expected frequency to be a number")
      end

      if frequency < 0
        raise ArgumentError.new("Expected frequency to be a positive number")
      end

      if !@worker_loop
        raise ArgumentError.new("Worker loop was not set")
      end

      klass = self

      stop

      @stop_thread = false

      @thread = Thread.new do
        while !@stop_thread
          begin
            @worker_loop.call
          rescue => e
            client.logger.error("#{klass} Prometheus Exporter Failed To Collect Stats #{e}")
          ensure
            sleep frequency
          end
        end
      end

    end

    def self.started?
      !!@thread&.alive?
    end

    def self.worker_loop(&blk)
      @worker_loop = blk
    end

    def self.stop
      # to avoid a warning
      @thread = nil if !defined?(@thread)

      if @thread&.alive?
        @stop_thread = true
        @thread.wakeup
        @thread.join
      end
      @thread = nil
    end

  end
end
