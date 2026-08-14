# frozen_string_literal: true

require "logger"
require "net/http"

module PrometheusExporter
  class Client
    class RemoteMetric
      attr_reader :name, :type, :help

      def initialize(name:, help:, type:, client:, opts: nil)
        @name = name
        @help = help
        @client = client
        @type = type
        @opts = opts
      end

      def standard_values(value, keys, prometheus_exporter_action = nil)
        values = { type: @type, help: @help, name: @name, keys: keys, value: value }
        values[
          :prometheus_exporter_action
        ] = prometheus_exporter_action if prometheus_exporter_action
        values[:opts] = @opts if @opts
        values
      end

      def observe(value = 1, keys = nil)
        @client.send_json(standard_values(value, keys))
      end

      def increment(keys = nil, value = 1)
        @client.send_json(standard_values(value, keys, :increment))
      end

      def decrement(keys = nil, value = 1)
        @client.send_json(standard_values(value, keys, :decrement))
      end
    end

    MAX_SOCKET_AGE = 25
    MAX_QUEUE_SIZE = 10_000
    # Built-in metric records are normally well under 1 KiB. Keep the historical
    # record-count limit, but also bound its realistic memory footprint.
    MAX_QUEUE_BYTES = MAX_QUEUE_SIZE * 1024
    # WEBrick's default InputBufferSize is 65,536 bytes. The legacy server passed
    # each input buffer to collectors as if it were a complete metric record.
    MAX_RECORD_SIZE = 64 * 1024
    DEFAULT_OPEN_TIMEOUT = 2
    DEFAULT_READ_TIMEOUT = 5
    DEFAULT_WRITE_TIMEOUT = 5

    attr_reader :logger

    def self.default
      @default ||= new
    end

    def self.default=(client)
      @default = client
    end

    def initialize(
      host: ENV.fetch("PROMETHEUS_EXPORTER_HOST", "localhost"),
      port: ENV.fetch("PROMETHEUS_EXPORTER_PORT", PrometheusExporter::DEFAULT_PORT),
      max_queue_size: nil,
      max_queue_bytes: nil,
      max_record_size: MAX_RECORD_SIZE,
      thread_sleep: 0.5,
      connect_timeout: nil,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT,
      write_timeout: DEFAULT_WRITE_TIMEOUT,
      json_serializer: nil,
      custom_labels: nil,
      logger: Logger.new(STDERR),
      log_level: Logger::WARN,
      process_queue_once_and_stop: false,
      tls_ca_file: nil,
      tls_cert_file: nil,
      tls_key_file: nil
    )
      @logger = logger
      @logger.level = log_level
      @metrics = []
      @queue = Queue.new
      @queued_bytes = 0
      @http = nil
      @http_started = nil
      @http_pid = nil
      @worker_thread = nil
      @mutex = Mutex.new
      @delivery_mutex = Mutex.new
      @delivery_lifecycle_mutex = Mutex.new
      @delivery_condition = ConditionVariable.new
      @in_flight = 0

      max_queue_size ||= MAX_QUEUE_SIZE
      max_queue_bytes ||= MAX_QUEUE_BYTES
      @max_queue_size = positive_integer(max_queue_size, "max_queue_size")
      @max_queue_bytes = positive_integer(max_queue_bytes, "max_queue_bytes")
      @max_record_size = positive_integer(max_record_size, "max_record_size")
      @host = host
      @port = port
      @thread_sleep = thread_sleep
      @open_timeout = positive_timeout(connect_timeout || open_timeout, "open_timeout")
      @read_timeout = positive_timeout(read_timeout, "read_timeout")
      @write_timeout = positive_timeout(write_timeout, "write_timeout")
      @json_serializer = json_serializer == :oj ? PrometheusExporter::OjCompat : JSON
      @custom_labels = custom_labels
      @process_queue_once_and_stop = process_queue_once_and_stop
      @tls_ca_file = tls_ca_file
      @tls_cert_file = tls_cert_file
      @tls_key_file = tls_key_file
      validate_tls_options!
    end

    def custom_labels=(custom_labels)
      @custom_labels = custom_labels
    end

    def register(type, name, help, opts = nil)
      metric = RemoteMetric.new(type: type, name: name, help: help, client: self, opts: opts)
      @metrics << metric
      metric
    end

    def find_registered_metric(name, type: nil, help: nil)
      @metrics.find do |metric|
        type_match = type ? metric.type == type : true
        help_match = help ? metric.help == help : true
        name_match = metric.name == name

        type_match && help_match && name_match
      end
    end

    def send_json(obj)
      payload =
        if @custom_labels
          if obj[:custom_labels]
            obj.merge(custom_labels: @custom_labels.merge(obj[:custom_labels]))
          else
            obj.merge(custom_labels: @custom_labels)
          end
        else
          obj
        end
      send(@json_serializer.dump(payload))
    end

    def send(str)
      record = str.dup
      if record.bytesize > @max_record_size
        logger.warn(
          "Prometheus Exporter client is dropping message cause metric record is " \
            "#{record.bytesize} bytes; maximum is #{@max_record_size} bytes",
        )
        return
      end

      @delivery_mutex.synchronize do
        @queue << record
        @queued_bytes += record.bytesize
        dropped = false
        while @queue.length > @max_queue_size || @queued_bytes > @max_queue_bytes
          dropped_record = @queue.pop
          @queued_bytes -= dropped_record.bytesize
          dropped = true
        end
        logger.warn "Prometheus Exporter client is dropping message cause queue is full" if dropped
        @delivery_condition.broadcast
      end

      ensure_worker_thread!
    end

    def process_queue
      @delivery_lifecycle_mutex.synchronize do
        close_http_if_old!
        process_queue_without_lock
      end
    end

    def stop(wait_timeout_seconds: 0)
      deadline = monotonic_now + [wait_timeout_seconds.to_f, 0].max

      @mutex.synchronize do
        wait_for_deliveries_until(deadline)
        @worker_thread&.kill
        @worker_thread&.join
        @worker_thread = nil
        @delivery_lifecycle_mutex.synchronize { close_http! }
      end
    end

    private

    def positive_integer(value, name)
      value = Integer(value)
      raise ArgumentError, "#{name} must be larger than 0" if value <= 0

      value
    rescue TypeError, ArgumentError
      raise ArgumentError, "#{name} must be larger than 0"
    end

    def positive_timeout(value, name)
      value = Float(value)
      raise ArgumentError if !value.finite? || value <= 0

      value
    rescue TypeError, ArgumentError
      raise ArgumentError, "#{name} must be a finite number larger than 0"
    end

    def validate_tls_options!
      options = [@tls_ca_file, @tls_cert_file, @tls_key_file]
      return if options.all?(&:nil?) || options.none?(&:nil?)

      raise ArgumentError,
            "tls_ca_file, tls_cert_file, and tls_key_file must be configured together"
    end

    def worker_loop
      process_queue
    rescue => e
      logger.error "Prometheus Exporter, failed to send message #{e}"
    end

    def ensure_worker_thread!
      if @process_queue_once_and_stop
        worker_loop
        return
      end

      unless @worker_thread&.alive?
        @mutex.synchronize do
          return if @worker_thread&.alive?

          @worker_thread =
            Thread.new do
              loop do
                worker_loop
                sleep @thread_sleep
              end
            end
        end
      end
    rescue ThreadError => e
      raise unless e.message =~ /can't alloc thread/
      logger.error "Prometheus Exporter, failed to send message ThreadError #{e}"
    end

    def process_queue_without_lock
      while (message = dequeue_for_delivery)
        begin
          response = deliver(message)
          raise "HTTP #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
        rescue => e
          logger.warn "Prometheus Exporter is dropping a message: #{e}"
          close_http!
          raise
        ensure
          finish_delivery
        end
      end
    end

    def dequeue_for_delivery
      @delivery_mutex.synchronize do
        message = @queue.pop(true)
        @queued_bytes -= message.bytesize
        @in_flight += 1
        message
      rescue ThreadError
        nil
      end
    end

    def finish_delivery
      @delivery_mutex.synchronize do
        @in_flight -= 1
        @delivery_condition.broadcast
      end
    end

    def deliver(message)
      ensure_http!
      request = Net::HTTP::Post.new("/send-metrics")
      request["Content-Type"] = "application/octet-stream"
      request["Content-Length"] = message.bytesize.to_s
      request.body = message
      @http.request(request)
    end

    def close_http!
      @http.finish if @http&.started?
    rescue IOError, SystemCallError
    ensure
      @http = nil
      @http_started = nil
      @http_pid = nil
    end

    def abandon_inherited_http!
      # Never call Net::HTTP#finish here. For TLS it performs SSL_shutdown and
      # sends close_notify on the inherited connection, which also terminates
      # the parent's session. Close only the child's duplicate raw descriptor;
      # bypassing SSLSocket#close performs no TLS protocol shutdown.
      buffered_io = @http.instance_variable_get(:@socket)
      transport = buffered_io&.io
      raw_io = transport.respond_to?(:to_io) ? transport.to_io : transport
      raw_io.close if raw_io && !raw_io.closed?
    rescue IOError, SystemCallError
      nil
    ensure
      @http = nil
      @http_started = nil
      @http_pid = nil
    end

    def close_http_if_old!
      if @http_pid == Process.pid && @http && @http_started &&
           ((@http_started + MAX_SOCKET_AGE) < Time.now.to_f)
        close_http!
      end
    end

    def ensure_http!
      abandon_inherited_http! if @http && @http_pid != Process.pid

      close_http_if_old!
      return if @http&.started?

      @http = Net::HTTP.new(@host, @port)
      @http.open_timeout = @open_timeout
      @http.read_timeout = @read_timeout
      @http.write_timeout = @write_timeout
      @http.max_retries = 0
      configure_tls! if use_ssl?
      @http.start
      @http_started = Time.now.to_f
      @http_pid = Process.pid
    rescue StandardError
      close_http!
      raise
    end

    def use_ssl?
      !@tls_ca_file.nil?
    end

    def configure_tls!
      require "openssl"

      @http.use_ssl = true
      @http.ca_file = @tls_ca_file
      @http.cert = OpenSSL::X509::Certificate.new(File.read(@tls_cert_file))
      @http.key = OpenSSL::PKey.read(File.read(@tls_key_file))
      @http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      @http.verify_hostname = true
    end

    def wait_for_deliveries_until(deadline)
      @delivery_mutex.synchronize do
        while @queue.length > 0 || @in_flight > 0
          remaining = deadline - monotonic_now
          break if remaining <= 0

          @delivery_condition.wait(@delivery_mutex, remaining)
        end
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  class LocalClient < Client
    attr_reader :collector

    def initialize(collector:, json_serializer: nil, custom_labels: nil)
      @collector = collector
      super(json_serializer: json_serializer, custom_labels: custom_labels)
    end

    def send(json)
      @collector.process(json)
    end
  end
end
