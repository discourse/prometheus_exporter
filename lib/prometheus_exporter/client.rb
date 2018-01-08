# frozen_string_literal: true

require 'json'
require 'socket'

class PrometheusExporter::Client

  MAX_SOCKET_AGE = 25
  MAX_QUEUE_SIZE = 10_000

  def initialize(host:, port:, max_queue_size: nil, manual_mode: false)
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
    @manual_mode = manual_mode

  end

  def send(obj)
    @queue << obj.to_json
    if @queue.length > @max_queue_size
      STDERR.puts "Prometheus Exporter client is dropping message cause queue is full"
      @queue.pop
    end
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
      rescue
        @queue.unshift message
        @socket = nil
        raise
      end
    end
  end

  def stop
    close_socket!
  end

  private

  def close_socket!
    if @socket
      @socket.write("0\r\n")
      @socket.write("\r\n")
      @socket.flush
      @socket.close
      @socket = nil
      @socket_started = nil
    end
  end

  def ensure_socket!
    if @socket && ((@socket_started + MAX_SOCKET_AGE) > Time.now.to_f)
      close_socket!
    end
    @socket = TCPSocket.new @host, @port

    @socket.write("POST /send-metrics HTTP/1.1\r\n")
    @socket.write("Transfer-Encoding: chunked\r\n")
    @socket.write("Connection: Close\r\n")
    @socket.write("Content-Type: application/octet-stream\r\n")
    @socket.write("\r\n")

    @socket_started = Time.now.to_f

    nil
  rescue
    @socket = nil
    @socket_started = nil
    raise
  end

end
