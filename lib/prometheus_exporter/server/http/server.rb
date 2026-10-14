# frozen_string_literal: true
#
# This file contains logic derived from WEBrick GenericServer, HTTPServer,
# HTTPResponse, and Utils listener handling.
# Copyright (c) 2000, 2001 TAKAHASHI Masayoshi, GOTOU Yuuzou.
# Copyright (c) 2002 Internet Programming with Ruby writers. All rights reserved.
# Vendored from WEBrick commit 25b0e9206bf5991c6274893d53c428d23b3f2292.
# See VENDORED_WEBRICK_LICENSE.txt for the BSD-2-Clause terms.

require "socket"
require_relative "request"

module PrometheusExporter
  module Server
    module HTTP
      class Server
        DEFAULT_MAX_CLIENTS = 100
        DEFAULT_REQUEST_TIMEOUT = 30
        DEFAULT_SHUTDOWN_TIMEOUT = 5
        DEFAULT_WRITE_TIMEOUT = 30
        HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
        INVALID_HEADER_VALUE = /[\x00-\x08\x0A-\x1F\x7F]/n

        def initialize(
          bind:,
          port:,
          logger:,
          max_clients: DEFAULT_MAX_CLIENTS,
          request_timeout: DEFAULT_REQUEST_TIMEOUT,
          shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT,
          write_timeout: DEFAULT_WRITE_TIMEOUT,
          ssl_context: nil,
          &handler
        )
          raise ArgumentError, "handler is required" unless handler
          raise ArgumentError, "max_clients must be positive" unless max_clients.to_i.positive?

          @request_timeout = positive_timeout(request_timeout, "request_timeout")
          @shutdown_timeout = positive_timeout(shutdown_timeout, "shutdown_timeout")
          @write_timeout = positive_timeout(write_timeout, "write_timeout")
          @bind = bind
          @port = Integer(port)
          @logger = logger
          @handler = handler
          @ssl_context = ssl_context
          @tokens = Thread::SizedQueue.new(max_clients.to_i)
          max_clients.to_i.times { @tokens.push(nil) }

          @mutex = Mutex.new
          @state_changed = ConditionVariable.new
          @state = :new
          @listeners = []
          @client_sockets = {}
          @client_threads = []
          @accept_thread = nil
          @shutdown_pipe = nil
        end

        def listeners
          @mutex.synchronize { @listeners.dup }
        end

        def start
          @mutex.synchronize do
            raise "server cannot be started from #{@state} state" unless @state == :new

            @state = :starting
            begin
              @shutdown_pipe = IO.pipe
              @listeners = create_listeners(@bind, @port)
              @accept_thread = Thread.new { accept_main }
            rescue Exception
              close_resources_locked
              @state = :stopped
              @state_changed.broadcast
              raise
            end

            @state_changed.wait(@mutex) while @state == :starting
            raise "server was shut down during startup" unless @state == :running

            @accept_thread
          end
        end

        def shutdown
          deadline = monotonic_now + @shutdown_timeout
          resources = begin_shutdown(deadline)
          return unless resources

          listeners, sockets, pipe, threads = resources
          signal_pipe(pipe)
          listeners.each { |listener| close_socket(listener) }
          sockets.each { |socket| close_socket(socket) }
          join_until_deadline(threads, deadline)
          threads.each { |thread| thread.kill if thread != Thread.current && thread.alive? }
          pipe&.each { |io| close_socket(io) }
        ensure
          finish_shutdown if resources
        end

        private

        class WriteTimeout < StandardError
        end

        class InvalidResponseHeader < StandardError
        end

        def positive_timeout(value, name)
          timeout = Float(value)
          unless timeout.positive? && timeout.finite?
            raise ArgumentError, "#{name} must be positive"
          end

          timeout
        rescue TypeError, ArgumentError
          raise ArgumentError, "#{name} must be positive"
        end

        def create_listeners(address, port)
          Socket.tcp_server_sockets(address, port)
        end

        def accept_main
          run =
            @mutex.synchronize do
              if @state == :starting
                @state = :running
                @state_changed.broadcast
                true
              else
                @state_changed.broadcast
                false
              end
            end
          accept_loop if run
        rescue StandardError => e
          @logger.error("HTTP accept loop failed: #{e.class}: #{e.message}") if running?
        ensure
          shutdown if running?
        end

        def accept_loop
          loop do
            selectable =
              @mutex.synchronize do
                if @state == :running
                  read_pipe = @shutdown_pipe&.first
                  @tokens.empty? ? [read_pipe] : [read_pipe, *@listeners]
                end
              end
            break unless selectable

            readable = IO.select(selectable)&.first
            break unless readable

            read_pipe = @mutex.synchronize { @shutdown_pipe&.first }
            if read_pipe && readable.delete(read_pipe)
              drain_pipe(read_pipe)
              break unless running?
            end

            readable.each do |listener|
              break unless running?
              next unless reserve_client_slot

              return_client_slot unless accept_and_publish_client(listener)
            end
          end
        rescue Errno::EBADF, Errno::ENOTSOCK, IOError
          nil
        end

        def reserve_client_slot
          @tokens.pop(true)
          true
        rescue ThreadError
          false
        end

        # Accepting, publishing the socket, and publishing its blocked thread are
        # one lifecycle operation. Shutdown either sees all of them or wins first.
        def accept_and_publish_client(listener)
          gate = Thread::Queue.new
          socket = nil
          thread = nil

          @mutex.synchronize do
            return false unless @state == :running

            socket = accept_client(listener)
            return false unless socket

            @client_sockets[socket] = true
            thread = Thread.new { client_main(socket) if gate.pop }
            @client_threads << thread
          rescue Exception
            @client_sockets.delete(socket)
            close_socket(socket) if socket
            thread&.kill
            raise
          end

          gate << true
          true
        end

        def accept_client(listener)
          case socket = listener.accept_nonblock(exception: false)
          when :wait_readable
            nil
          when Array
            socket.first
          else
            socket
          end
        rescue Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPROTO, Errno::EINVAL
          nil
        end

        def client_main(raw_socket)
          socket = raw_socket
          begin
            return unless running?

            if @ssl_context
              socket = wrap_tls(raw_socket)
              return unless publish_wrapped_socket(socket)
            end
            handle_client(socket)
          rescue StandardError => e
            @logger.error("HTTP client failed: #{e.class}: #{e.message}") if running?
          ensure
            unregister_socket(socket)
            unregister_socket(raw_socket)
            close_socket(socket)
            close_socket(raw_socket) unless socket.equal?(raw_socket)
            return_client_slot
            unregister_thread(Thread.current)
          end
        end

        def publish_wrapped_socket(socket)
          @mutex.synchronize do
            return false unless @state == :running

            @client_sockets[socket] = true
          end
          true
        end

        def wrap_tls(socket)
          require "openssl"

          ssl_socket = OpenSSL::SSL::SSLSocket.new(socket, @ssl_context)
          ssl_socket.sync_close = true
          Timeout.timeout(@request_timeout) { ssl_socket.accept }
          ssl_socket
        end

        def handle_client(socket)
          loop do
            request = nil
            response = nil
            close_connection = false

            begin
              request = Request.new(socket, read_timeout: @request_timeout).parse
              response = @handler.call(request)
              if response.status == 405
                close_connection = true
              else
                request.finish
              end
            rescue EndOfStream
              break
            rescue Error => e
              response = error_response(e.status, e.message)
              close_connection = true
            rescue StandardError => e
              @logger.error("HTTP request failed: #{e.class}: #{e.message}")
              response = error_response(500, HTTP.status_message(500))
              close_connection = true
            end

            break unless response

            keep_alive = !close_connection && request&.method != "CONNECT" && request&.keep_alive?
            keep_alive = write_response(socket, request, response, keep_alive: keep_alive)
            break unless keep_alive
          end
        end

        def error_response(status, message)
          reason = HTTP.status_message(status)
          Response.new(status: status, body: "#{reason}: #{message}\n")
        end

        def write_response(socket, request, response, keep_alive:)
          output, status, keep_alive = serialize_response(request, response, keep_alive)
          response.status = status
          write_with_timeout(socket, output)
          keep_alive
        rescue WriteTimeout, Errno::EPIPE, Errno::ECONNRESET, IOError, SystemCallError
          false
        end

        def serialize_response(request, response, keep_alive)
          version = request&.http_version == "1.0" ? "1.0" : "1.1"
          status = normalize_status(response.status)
          body = response.body.to_s
          body_forbidden = (100..199).cover?(status) || [204, 205, 304].include?(status)
          headers = response.headers.dup
          if body_forbidden
            body = ""
            headers.delete_if do |name, _value|
              %w[content-length transfer-encoding].include?(name.to_s.downcase)
            end
            headers["Content-Length"] = "0" if status == 205
          else
            headers = {
              "Content-Type" => "text/plain; charset=utf-8",
              "Content-Length" => body.bytesize.to_s,
            }.merge(headers)
          end
          headers["Connection"] = "close" unless keep_alive
          headers["Connection"] = "Keep-Alive" if keep_alive && version == "1.0"
          headers = validated_headers(headers)

          output = +"HTTP/#{version} #{status} #{HTTP.status_message(status)}\r\n".b
          headers.each { |name, value| output << "#{name}: #{value}\r\n" }
          output << "\r\n"
          output << body unless request&.method == "HEAD"
          [output, status, keep_alive]
        rescue InvalidResponseHeader => e
          @logger.error("Invalid HTTP response header: #{e.message}")
          body = "Internal Server Error\n"
          output =
            +"HTTP/#{version} 500 #{HTTP.status_message(500)}\r\n" \
              "Content-Type: text/plain; charset=utf-8\r\n" \
              "Content-Length: #{body.bytesize}\r\n" \
              "Connection: close\r\n\r\n".b
          output << body unless request&.method == "HEAD"
          [output, 500, false]
        end

        def normalize_status(status)
          code =
            if status.is_a?(Integer)
              status
            elsif status.is_a?(String) && /\A\d{3}\z/.match?(status)
              status.to_i
            end
          code && (100..599).cover?(code) ? code : 500
        end

        def validated_headers(headers)
          seen_names = {}
          headers.to_h do |raw_name, raw_value|
            name = raw_name.to_s
            normalized_name = name.downcase
            value = raw_value.to_s
            raise InvalidResponseHeader, "invalid name" unless HEADER_NAME.match?(name)
            raise InvalidResponseHeader, "duplicate name #{name}" if seen_names[normalized_name]
            if normalized_name == "transfer-encoding"
              raise InvalidResponseHeader, "unsupported transfer-encoding"
            end
            if INVALID_HEADER_VALUE.match?(value)
              raise InvalidResponseHeader, "invalid value for #{name}"
            end

            seen_names[normalized_name] = true
            [name, value]
          end
        end

        def write_with_timeout(socket, output)
          deadline = monotonic_now + @write_timeout
          offset = 0
          while offset < output.bytesize
            written =
              socket.write_nonblock(
                output.byteslice(offset, output.bytesize - offset),
                exception: false,
              )
            case written
            when Integer
              offset += written
            when :wait_readable
              wait_for_io(socket, readable: true, deadline: deadline)
            when :wait_writable
              wait_for_io(socket, readable: false, deadline: deadline)
            else
              raise IOError, "response write failed"
            end
          end
        end

        def wait_for_io(socket, readable:, deadline:)
          remaining = deadline - monotonic_now
          raise WriteTimeout if remaining <= 0

          ready =
            if readable
              IO.select([socket], nil, nil, remaining)
            else
              IO.select(nil, [socket], nil, remaining)
            end
          raise WriteTimeout unless ready
        end

        def begin_shutdown(deadline)
          @mutex.synchronize do
            case @state
            when :new
              @state = :stopped
              @state_changed.broadcast
              return nil
            when :starting, :running
              @state = :stopping
              @state_changed.broadcast
              listeners = @listeners
              @listeners = []
              sockets = @client_sockets.keys
              pipe = @shutdown_pipe
              threads = [@accept_thread, *@client_threads].compact.uniq
              return listeners, sockets, pipe, threads
            when :stopping
              remaining = deadline - monotonic_now
              while @state == :stopping && remaining.positive?
                @state_changed.wait(@mutex, remaining)
                remaining = deadline - monotonic_now
              end
              return nil
            when :stopped
              return nil
            end
          end
        end

        def finish_shutdown
          @mutex.synchronize do
            @listeners = []
            @shutdown_pipe = nil
            @state = :stopped
            @state_changed.broadcast
          end
        end

        def close_resources_locked
          @listeners.each { |listener| close_socket(listener) }
          @shutdown_pipe&.each { |io| close_socket(io) }
          @listeners = []
          @shutdown_pipe = nil
        end

        def join_until_deadline(threads, deadline)
          threads.each do |thread|
            next if thread == Thread.current

            remaining = deadline - monotonic_now
            break unless remaining.positive?

            thread.join(remaining)
          end
        end

        def running?
          @mutex.synchronize { @state == :running }
        end

        def unregister_socket(socket)
          @mutex.synchronize { @client_sockets.delete(socket) }
        end

        def unregister_thread(thread)
          @mutex.synchronize { @client_threads.delete(thread) }
          signal_pipe(@mutex.synchronize { @shutdown_pipe }) if running?
        end

        def return_client_slot
          @tokens.push(nil)
        end

        def signal_pipe(pipe)
          writer = pipe&.last
          writer&.write_nonblock("\0") unless writer&.closed?
        rescue IO::WaitWritable, Errno::EPIPE, IOError
          nil
        end

        def drain_pipe(reader)
          buffer = +""
          nil while reader.read_nonblock(64, buffer, exception: false).is_a?(String)
        rescue IOError, SystemCallError
          nil
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def close_socket(socket)
          socket.close unless socket.closed?
        rescue IOError, SystemCallError
          nil
        end
      end
    end
  end
end
