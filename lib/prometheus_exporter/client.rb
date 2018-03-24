# frozen_string_literal: true

require 'socket'
require 'thread'

class PrometheusExporter::Client

  class RemoteMetric
    def initialize(name:, help:, type:, client:)
      @name = name
      @help = help
      @client = client
      @type = type
    end

    def observe(value = 1, keys = nil)
      @client.send_json(
        type: @type,
        help: @help,
        name: @name,
        keys: keys,
        value: value
      )
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

  def initialize(host: 'localhost', port: PrometheusExporter::DEFAULT_PORT, max_queue_size: nil, thread_sleep: 0.5, json_serializer: nil)
    @metrics = []

    @queue = Queue.new
    @socket = nil
    @socket_started = nil

    max_queue_size ||= MAX_QUEUE_SIZE
    max_queue_size = max_queue_size.to_i

    if max_queue_size.to_i <= 0
      raise ArgumentError, "max_queue_size must be larger than 0"
    end

    @max_queue_size = max_queue_size
    @host = host
    @port = port
    @worker_thread = nil
    @mutex = Mutex.new
    @thread_sleep = thread_sleep

    @json_serializer = json_serializer == :oj ? PrometheusExporter::OjCompat : JSON
  end

  def register(type, name, help)
    metric = RemoteMetric.new(type: type, name: name, help: help, client: self)
    @metrics << metric
    metric
  end

  def send_json(obj)
    send(@json_serializer.dump(obj))
  end

  def send(str)
    @queue << str
    if @queue.length > @max_queue_size
      STDERR.puts "Prometheus Exporter client is dropping message cause queue is full"
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
        STDERR.puts "Prometheus Exporter is dropping a message: #{e}"
        @socket = nil
        raise
      end
    end
  end

  def stop
    @mutex.synchronize do
      @worker_thread.try!(:kill)
      while @worker_thread.alive?
        sleep 0.001
      end
      @worker_thread = nil
    end

    close_socket!
  end

  private

  def worker_loop
    close_socket_if_old!
    process_queue
  rescue => e
    STDERR.puts "Prometheus Exporter, failed to send message #{e}"
  end

  def ensure_worker_thread!
    unless @worker_thread.try!(:alive?)
      @mutex.synchronize do
        return if @worker_thread.try!(:alive?)

        @worker_thread = Thread.new do
          while true
            worker_loop
            sleep @thread_sleep
          end
        end
      end
    end
  end

  def close_socket!
    begin
      if @socket
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
    if @socket && ((@socket_started + MAX_SOCKET_AGE) < Time.now.to_f)
      close_socket!
    end
  end

  def ensure_socket!
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
    end

    nil
  rescue
    @socket = nil
    @socket_started = nil
    raise
  end

end
