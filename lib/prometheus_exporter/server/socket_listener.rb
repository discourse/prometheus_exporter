# frozen_string_literal: true

require "socket"

require_relative "http_connection"

module PrometheusExporter::Server
  # Owns listening sockets, TLS handshakes, connection admission, workers, and
  # bounded shutdown. HTTP parsing and application behavior live elsewhere.
  class SocketListener
    ACCEPT_RETRY_INITIAL_DELAY = 0.01
    ACCEPT_RETRY_MAX_DELAY = 0.25
    private_constant :ACCEPT_RETRY_INITIAL_DELAY, :ACCEPT_RETRY_MAX_DELAY

    def initialize(
      port:,
      bind:,
      tls_cert_file:,
      tls_key_file:,
      max_connections:,
      timeouts:,
      limits:,
      logger:,
      verbose:,
      request_handler:
    )
      @port = port
      @bind = bind
      @max_connections = max_connections
      @header_timeout = timeouts.fetch(:header)
      @stop_timeout = timeouts.fetch(:stop)
      @connection_timeouts = timeouts.slice(:body_read, :write)
      @connection_limits = limits
      @logger = logger
      @verbose = verbose
      @request_handler = request_handler
      @ssl_context = build_ssl_context(tls_cert_file, tls_key_file)

      @state_mutex = Mutex.new
      @workers = {}
      @clients = {}
      @stopping = false
      @accept_error = nil
      @listeners = build_listeners
      @wakeup_reader, @wakeup_writer = IO.pipe
    end

    def start
      @state_mutex.synchronize do
        return @runner if @runner

        @accept_error = nil
        @runner = Thread.new { accept_loop }
      end
    end

    def stop
      runner = nil
      listeners = nil
      wakeup_writer = nil

      @state_mutex.synchronize do
        return if @stopping

        @stopping = true
        listeners = @listeners
        @listeners = nil
        wakeup_writer = @wakeup_writer
        runner = @runner
      end

      Array(listeners).each { |listener| close_quietly(listener) }
      stop_deadline = monotonic_deadline(@stop_timeout)
      begin
        wakeup_writer&.write_nonblock(".")
      rescue IOError, SystemCallError
        nil
      end
      accept_threads = [runner].compact - [Thread.current]
      join_threads_until(accept_threads, stop_deadline)
      accept_threads.each { |thread| thread.kill if thread.alive? }
      join_threads_until(accept_threads, monotonic_deadline(0.1))

      clients = @state_mutex.synchronize { @clients.keys }
      clients.each { |socket| close_quietly(socket) }

      workers = @state_mutex.synchronize { @workers.keys - [Thread.current] }
      join_threads_until(workers, stop_deadline)
      workers.each { |worker| worker.kill if worker.alive? }
      join_threads_until(workers, monotonic_deadline(0.1))

      close_quietly(@wakeup_reader)
      close_quietly(@wakeup_writer)
      @state_mutex.synchronize do
        @runner = nil
        @wakeup_reader = nil
        @wakeup_writer = nil
      end
      nil
    end

    def accept_error
      @state_mutex.synchronize { @accept_error }
    end

    def local_port
      @state_mutex.synchronize { @listeners&.first&.local_address&.ip_port }
    end

    private

    def build_ssl_context(cert_file, key_file)
      if cert_file.nil? != key_file.nil?
        raise ArgumentError, "tls_cert_file and tls_key_file must be supplied together"
      end
      return unless cert_file

      # Loading the exporter for plain HTTP must not load OpenSSL.
      require "openssl"
      certificate = OpenSSL::X509::Certificate.new(File.read(cert_file))
      private_key = OpenSSL::PKey.read(File.read(key_file))
      unless certificate.check_private_key(private_key)
        raise ArgumentError, "tls_cert_file and tls_key_file do not match"
      end

      context = OpenSSL::SSL::SSLContext.new
      context.cert = certificate
      context.key = private_key
      context
    end

    def build_listeners
      addresses = bind_addresses
      listeners = []
      port = @port
      errors = []

      addresses.each do |family, address|
        begin
          listener = Socket.new(family, Socket::SOCK_STREAM, 0)
          listener.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
          set_ipv6_only(listener) if family == Socket::AF_INET6
          listener.bind(Socket.sockaddr_in(port, address))
          listener.listen(Socket::SOMAXCONN)
          port = listener.local_address.ip_port if port.to_i.zero?
          listeners << listener
        rescue SystemCallError, SocketError => e
          close_quietly(listener)
          errors << e
        end
      end

      raise(errors.first || SocketError.new("No usable bind addresses")) if listeners.empty?

      listeners
    rescue StandardError
      listeners&.each { |listener| close_quietly(listener) }
      raise
    end

    def bind_addresses
      return [Socket::AF_INET6, "::"], [Socket::AF_INET, "0.0.0.0"] unless @bind

      Addrinfo
        .getaddrinfo(@bind, @port, nil, :STREAM, nil, Socket::AI_PASSIVE)
        .filter_map do |address|
          case address.afamily
          when Socket::AF_INET, Socket::AF_INET6
            [address.afamily, address.ip_address]
          end
        end
        .uniq
    end

    def set_ipv6_only(listener)
      return unless Socket.const_defined?(:IPV6_V6ONLY)

      listener.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, 1)
    rescue SystemCallError
      # Some platforms expose IPV6_V6ONLY but do not allow changing it.
    end

    def accept_loop
      retry_delay = ACCEPT_RETRY_INITIAL_DELAY

      loop do
        state = accept_state
        break unless state

        listeners, wakeup_reader, at_capacity = state
        readers = at_capacity ? [wakeup_reader] : listeners + [wakeup_reader]
        ready = IO.select(readers)
        next unless ready

        if ready.first.include?(wakeup_reader)
          drain_wakeup
          next
        end

        ready.first.each do |listener|
          break unless worker_capacity_available?

          begin
            accepted = accept_socket(listener)
          rescue Errno::ECONNABORTED
            next
          rescue Errno::EMFILE, Errno::ENFILE => e
            @logger.warn "Temporarily unable to accept prometheus exporter connection: #{e}"
            wait_for_accept_retry(retry_delay)
            retry_delay = [retry_delay * 2, ACCEPT_RETRY_MAX_DELAY].min
            break
          end
          next if accepted == :wait_readable

          retry_delay = ACCEPT_RETRY_INITIAL_DELAY
          socket = accepted.is_a?(Array) ? accepted.first : accepted
          spawn_worker(socket)
        rescue IOError, Errno::EBADF, Errno::EINVAL
          raise unless stopping?
        end
      end
    rescue => e
      unless stopping?
        @state_mutex.synchronize { @accept_error = e }
        @logger.error "Failed to run prometheus collector web on port #{@port}: #{e}"
      end
    ensure
      @state_mutex.synchronize { @runner = nil if @runner == Thread.current }
    end

    def accept_state
      @state_mutex.synchronize do
        unless @stopping || !@listeners || @listeners.empty?
          [@listeners.dup, @wakeup_reader, @workers.length >= @max_connections]
        end
      end
    end

    def accept_socket(listener)
      listener.accept_nonblock(exception: false)
    end

    def worker_capacity_available?
      @state_mutex.synchronize { !@stopping && @workers.length < @max_connections }
    end

    def wait_for_accept_retry(delay)
      ready = IO.select([@wakeup_reader], nil, nil, delay)
      drain_wakeup if ready
    rescue IOError, Errno::EBADF
      raise unless stopping?
    end

    def drain_wakeup
      loop do
        result = @wakeup_reader.read_nonblock(1024, exception: false)
        break if result == :wait_readable || result.nil?
      end
    rescue IOError, Errno::EBADF
      raise unless stopping?
    end

    def wake_accept_loop
      @wakeup_writer&.write_nonblock(".", exception: false)
    rescue IOError, SystemCallError
      nil
    end

    def spawn_worker(socket)
      reject = false

      @state_mutex.synchronize do
        if @stopping || @workers.length >= @max_connections
          reject = true
        else
          worker = Thread.new { serve_client(socket) }
          @clients[socket] = true
          @workers[worker] = true
        end
      end

      # Capacity is checked before accept; rejection is only possible when
      # shutdown races with an accepted connection.
      close_quietly(socket) if reject
    rescue ThreadError => e
      close_quietly(socket)
      @logger.error "Failed to allocate prometheus exporter worker: #{e}"
    end

    def serve_client(socket)
      io = nil
      header_deadline = monotonic_deadline(@header_timeout)
      io = wrap_tls(socket, header_deadline)
      build_connection(io).handle(header_deadline)
    rescue HTTPConnection::Error, IOError, SystemCallError
      # TLS negotiation failed or the peer disconnected before HTTP handling.
    rescue => e
      unless ssl_error?(e)
        if @verbose
          @logger.error "Prometheus exporter request failed: #{e.inspect}\n#{Array(e.backtrace).join("\n")}"
        end
      end
    ensure
      close_quietly(io) if io && io != socket
      close_quietly(socket)
      @state_mutex.synchronize do
        @clients.delete(socket)
        @workers.delete(Thread.current)
      end
      wake_accept_loop
    end

    def build_connection(socket)
      HTTPConnection.new(
        socket,
        request_handler: @request_handler,
        logger: @logger,
        verbose: @verbose,
        limits: @connection_limits,
        timeouts: @connection_timeouts,
        ssl_error: method(:ssl_error?),
      )
    end

    def wrap_tls(socket, deadline)
      return socket unless @ssl_context

      ssl_socket = OpenSSL::SSL::SSLSocket.new(socket, @ssl_context)
      ssl_socket.sync_close = false

      loop do
        result = ssl_socket.accept_nonblock(exception: false)
        case result
        when :wait_readable
          wait_for(socket, :read, deadline)
        when :wait_writable
          wait_for(socket, :write, deadline)
        else
          return ssl_socket
        end
      end
    end

    def wait_for(socket, direction, deadline)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise HTTPConnection::Error.new(408, "Request timed out") if remaining <= 0

      readers = direction == :read ? [socket] : nil
      writers = direction == :write ? [socket] : nil
      unless IO.select(readers, writers, nil, remaining)
        raise HTTPConnection::Error.new(408, "Request timed out")
      end
    end

    def ssl_error?(error)
      return false unless Object.const_defined?(:OpenSSL, false)

      openssl = Object.const_get(:OpenSSL, false)
      return false unless openssl.const_defined?(:SSL, false)

      ssl = openssl.const_get(:SSL, false)
      ssl.const_defined?(:SSLError, false) && error.is_a?(ssl.const_get(:SSLError, false))
    end

    def join_threads_until(threads, deadline)
      threads.each do |thread|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        thread.join(remaining) if remaining.positive?
      end
    end

    def monotonic_deadline(timeout)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    end

    def stopping?
      @state_mutex.synchronize { @stopping }
    end

    def close_quietly(socket)
      return unless socket

      begin
        socket.shutdown(Socket::SHUT_RDWR) if socket.respond_to?(:shutdown) && !socket.closed?
      rescue StandardError
        nil
      ensure
        begin
          socket.close unless socket.closed?
        rescue StandardError
          nil
        end
      end
    end
  end
  private_constant :SocketListener
end
