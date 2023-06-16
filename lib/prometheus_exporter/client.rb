# frozen_string_literal: true

require 'socket'
require 'thread'
require 'logger'

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
        values = {
          type: @type,
          help: @help,
          name: @name,
          keys: keys,
          value: value
        }
        values[:prometheus_exporter_action] = prometheus_exporter_action if prometheus_exporter_action
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

    def self.default
      @default ||= new
    end

    def self.default=(client)
      @default = client
    end

    MAX_SOCKET_AGE = 25
    MAX_QUEUE_SIZE = 10_000

    attr_reader :logger

    def initialize(
      host: ENV.fetch('PROMETHEUS_EXPORTER_HOST', 'localhost'),
      port: ENV.fetch('PROMETHEUS_EXPORTER_PORT', PrometheusExporter::DEFAULT_PORT),
      max_queue_size: nil,
      thread_sleep: 0.5,
      json_serializer: nil,
      custom_labels: nil,
      logger: Logger.new(STDERR),
      log_level: Logger::WARN
    )
      @logger = logger
      @logger.level = log_level
      @metrics = []

      @queue = Queue.new

      @socket = nil
      @socket_started = nil
      @socket_pid = nil

      max_queue_size ||= MAX_QUEUE_SIZE
      max_queue_size = max_queue_size.to_i

      if max_queue_size <= 0
        raise ArgumentError, "max_queue_size must be larger than 0"
      end

      @max_queue_size = max_queue_size
      @host = host
      @port = port
      @worker_thread = nil
      @mutex = Mutex.new
      @thread_sleep = thread_sleep

      @json_serializer = json_serializer == :oj ? PrometheusExporter::OjCompat : JSON

      @custom_labels = custom_labels
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
      @queue << str
      if @queue.length > @max_queue_size
        logger.warn "Prometheus Exporter client is dropping message cause queue is full"
        @queue.pop
      end

      ensure_worker_thread!
    end

    def process_queue
      while @queue.length > 0
        ensure_socket!

        begin
          message = @queue.pop
          @socket.write(message.bytesize.to_s(16).upcase)
          @socket.write("\r\n")
          @socket.write(message)
          @socket.write("\r\n")
        rescue => e
          logger.warn "Prometheus Exporter is dropping a message: #{e}"
          @socket = nil
          raise
        end
      end
    end

    def stop(wait_timeout_seconds: 0)
      @mutex.synchronize do
        wait_for_empty_queue_with_timeout(wait_timeout_seconds)
        @worker_thread&.kill
        while @worker_thread&.alive?
          sleep 0.001
        end
        @worker_thread = nil
        close_socket!
      end
    end

    private

    def worker_loop
      close_socket_if_old!
      process_queue
    rescue => e
      logger.error "Prometheus Exporter, failed to send message #{e}"
    end

    def ensure_worker_thread!
      unless @worker_thread&.alive?
        @mutex.synchronize do
          return if @worker_thread&.alive?

          @worker_thread = Thread.new do
            while true
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

    def close_socket!
      begin
        if @socket && !@socket.closed?
          @socket.write("0\r\n")
          @socket.write("\r\n")
          @socket.flush
          @socket.close
        end
      rescue Errno::EPIPE
      end

      @socket = nil
      @socket_started = nil
    end

    def close_socket_if_old!
      if @socket_pid == Process.pid && @socket && @socket_started && ((@socket_started + MAX_SOCKET_AGE) < Time.now.to_f)
        close_socket!
      end
    end

    def ensure_socket!
      # if process was forked socket may be owned by parent
      # leave it alone and reset
      if @socket_pid != Process.pid
        @socket = nil
        @socket_started = nil
        @socket_pid = nil
      end

      close_socket_if_old!
      if !@socket
        @socket = TCPSocket.new @host, @port
        @socket.write("POST /send-metrics HTTP/1.1\r\n")
        @socket.write("Transfer-Encoding: chunked\r\n")
        @socket.write("Host: #{@host}\r\n")
        @socket.write("Connection: Close\r\n")
        @socket.write("Content-Type: application/octet-stream\r\n")
        @socket.write("\r\n")
        @socket_started = Time.now.to_f
        @socket_pid = Process.pid
      end

      nil
    rescue
      @socket = nil
      @socket_started = nil
      @socket_pid = nil
      raise
    end

    def wait_for_empty_queue_with_timeout(timeout_seconds)
      start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      while @queue.length > 0
        break if start_time + timeout_seconds < ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        sleep(0.05)
      end
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
