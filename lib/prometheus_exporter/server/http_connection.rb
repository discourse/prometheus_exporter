# frozen_string_literal: true

module PrometheusExporter::Server
  # Handles one bounded HTTP/1.x request and response on an accepted socket.
  # Connections are deliberately single-use; every response closes the socket.
  class HTTPConnection
    Request = Struct.new(:method, :path, :version, :headers, keyword_init: true)

    class Error < StandardError
      attr_reader :status, :headers

      def initialize(status, message, headers = {})
        @status = status
        @headers = headers
        super(message)
      end
    end

    STATUS_TEXT = {
      200 => "OK",
      400 => "Bad Request",
      401 => "Unauthorized",
      404 => "Not Found",
      405 => "Method Not Allowed",
      408 => "Request Timeout",
      411 => "Length Required",
      413 => "Payload Too Large",
      417 => "Expectation Failed",
      422 => "Unprocessable Entity",
      429 => "Too Many Requests",
      431 => "Request Header Fields Too Large",
      500 => "Internal Server Error",
      503 => "Service Unavailable",
      505 => "HTTP Version Not Supported",
    }.freeze
    private_constant :STATUS_TEXT

    def initialize(socket, request_handler:, logger:, verbose:, limits:, timeouts:, ssl_error:)
      @socket = socket
      @request_handler = request_handler
      @logger = logger
      @verbose = verbose
      @max_request_line_bytes = limits.fetch(:request_line)
      @max_header_line_bytes = limits.fetch(:header_line)
      @max_header_bytes = limits.fetch(:headers)
      @max_header_count = limits.fetch(:header_count)
      @max_body_chunk_bytes = limits.fetch(:body_chunk)
      @body_read_timeout = timeouts.fetch(:body_read)
      @write_timeout = timeouts.fetch(:write)
      @ssl_error = ssl_error
    end

    def handle(header_deadline)
      reader = SocketReader.new(@socket)
      @body_reader = reader
      request = parse_request(reader.read_headers(@max_header_bytes, header_deadline))
      status, body, headers = @request_handler.call(request, self)
      write_response(status, body, headers)
    rescue Error => e
      write_response(e.status, e.message, e.headers)
    rescue IOError, SystemCallError
      # Clients commonly disconnect without reading the response.
    rescue => e
      return if @ssl_error.call(e)

      if @verbose
        @logger.error "Prometheus exporter request failed: #{e.inspect}\n#{Array(e.backtrace).join("\n")}"
      end
      write_response(500, "Internal Server Error", {})
    end

    def reject_body(request)
      if request.headers.key?("transfer-encoding")
        raise Error.new(400, "GET requests cannot use Transfer-Encoding")
      end

      content_length = parse_content_length(request.headers["content-length"])
      raise Error.new(400, "GET requests cannot contain a body") if content_length&.positive?
    end

    def each_body_chunk(request)
      transfer_encoding = request.headers["transfer-encoding"]
      content_length_header = request.headers["content-length"]

      if transfer_encoding
        unless transfer_encoding.downcase == "chunked"
          raise Error.new(400, "Only chunked Transfer-Encoding is supported")
        end
        each_chunked_body_chunk { |chunk| yield chunk }
      elsif content_length_header
        length = parse_content_length(content_length_header)
        raise Error.new(413, "Metrics payload is too large") if length > @max_body_chunk_bytes

        yield read_body(length) if length.positive?
      else
        raise Error.new(411, "A request body length is required")
      end
    end

    private

    def parse_request(raw_headers)
      lines = raw_headers.byteslice(0, raw_headers.bytesize - 4).split("\r\n", -1)
      request_line = lines.shift
      if request_line.bytesize > @max_request_line_bytes
        raise Error.new(400, "Malformed request line")
      end

      match = %r{\A([A-Z]+) ([^ ]+) HTTP/(\d\.\d)\z}n.match(request_line)
      raise Error.new(400, "Malformed request line") unless match

      method, target, version = match.captures
      case version
      when "1.0", "1.1"
        # Supported below.
      else
        raise Error.new(505, "HTTP version is not supported")
      end
      unless target.start_with?("/") && target.match?(/\A[\x21-\x7e]+\z/n) && !target.include?("#")
        raise Error.new(400, "Malformed request target")
      end
      raise Error.new(431, "Too many request headers") if lines.length > @max_header_count

      headers = parse_headers(lines)
      validate_framing(version, headers)

      Request.new(
        method: method,
        path: target.split("?", 2).first,
        version: version,
        headers: headers,
      )
    end

    def parse_headers(lines)
      headers = {}
      lines.each do |line|
        if line.bytesize > @max_header_line_bytes
          raise Error.new(431, "Request header line is too large")
        end
        if line.start_with?(" ", "\t")
          raise Error.new(400, "Obsolete folded headers are not supported")
        end

        header =
          /\A([!#$%&'*+\-.^_`|~0-9A-Za-z]+):[ \t]*([^\x00-\x08\x0a-\x1f\x7f]*)\z/n.match(line)
        raise Error.new(400, "Malformed request header") unless header

        name = header[1].downcase
        raise Error.new(400, "Duplicate request header") if headers.key?(name)

        headers[name] = header[2].strip
      end
      headers
    end

    def validate_framing(version, headers)
      host = headers["host"]
      if version == "1.1" && (!host || host.empty?)
        raise Error.new(400, "HTTP/1.1 requires a Host header")
      end
      raise Error.new(400, "Malformed Host header") if host&.match?(%r{[\x00-\x20,\x7f\\/]}n)
      raise Error.new(417, "Expect is not supported") if headers.key?("expect")
      if version == "1.0" && headers.key?("transfer-encoding")
        raise Error.new(400, "HTTP/1.0 does not support Transfer-Encoding")
      end
      if headers.key?("content-length") && headers.key?("transfer-encoding")
        raise Error.new(400, "Content-Length and Transfer-Encoding cannot be combined")
      end
    end

    def each_chunked_body_chunk
      reader = @body_reader
      loop do
        body_deadline = monotonic_deadline(@body_read_timeout)
        size_line = reader.read_line(@max_header_line_bytes, body_deadline)
        raise Error.new(400, "Malformed chunk size") unless size_line.match?(/\A[0-9A-Fa-f]+\z/n)
        raise Error.new(413, "Metrics chunk is too large") if size_line.bytesize > 16

        size = size_line.to_i(16)
        raise Error.new(413, "Metrics chunk is too large") if size > @max_body_chunk_bytes

        if size.zero?
          trailer = reader.read_line(@max_header_line_bytes, body_deadline)
          raise Error.new(400, "Chunk trailers are not supported") unless trailer.empty?

          break
        end

        chunk = reader.read_exact(size, body_deadline)
        unless reader.read_exact(2, body_deadline) == "\r\n"
          raise Error.new(400, "Malformed chunk framing")
        end
        yield chunk
      end
    end

    def read_body(length)
      @body_reader.read_exact(length, monotonic_deadline(@body_read_timeout))
    end

    def parse_content_length(value)
      return unless value
      raise Error.new(400, "Malformed Content-Length") unless value.match?(/\A(?:0|[1-9][0-9]*)\z/n)

      value.to_i
    end

    def write_response(status, body, headers)
      return if @socket.closed?

      status = 500 unless status.is_a?(Integer) && status.between?(100, 599)
      body = body.to_s.b
      reason = STATUS_TEXT.fetch(status, "Error")
      response_headers = {
        "Content-Type" => "text/plain; charset=utf-8",
        "Content-Length" => body.bytesize.to_s,
        "Connection" => "close",
      }.merge(headers)
      response = +"HTTP/1.1 #{status} #{reason}\r\n"
      response_headers.each do |name, value|
        name = name.to_s
        value = value.to_s
        unless name.match?(/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/n) &&
                 value.match?(/\A[^\x00-\x1f\x7f]*\z/n)
          raise ArgumentError, "Invalid response header"
        end
        response << "#{name}: #{value}\r\n"
      end
      response << "\r\n"
      response << body
      write_all_nonblock(response, monotonic_deadline(@write_timeout))
    rescue ArgumentError, Error, IOError, SystemCallError
      nil
    rescue => e
      raise unless @ssl_error.call(e)
    end

    def write_all_nonblock(string, deadline)
      offset = 0
      while offset < string.bytesize
        result =
          @socket.write_nonblock(
            string.byteslice(offset, string.bytesize - offset),
            exception: false,
          )
        case result
        when :wait_readable
          wait_for(:read, deadline)
        when :wait_writable
          wait_for(:write, deadline)
        else
          raise IOError, "Response socket made no write progress" unless result.positive?

          offset += result
        end
      end
    end

    def wait_for(direction, deadline)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Error.new(408, "Request timed out") if remaining <= 0

      readers = direction == :read ? [@socket] : nil
      writers = direction == :write ? [@socket] : nil
      raise Error.new(408, "Request timed out") unless IO.select(readers, writers, nil, remaining)
    end

    def monotonic_deadline(timeout)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    end

    class SocketReader
      def initialize(socket)
        @socket = socket
        @buffer = +""
        @buffer.force_encoding(Encoding::BINARY)
      end

      def read_headers(max_bytes, deadline)
        loop do
          if (ending = @buffer.index("\r\n\r\n"))
            length = ending + 4
            raise Error.new(431, "Request headers are too large") if length > max_bytes

            return consume(length)
          end

          ensure_before_deadline(deadline)
          raise Error.new(400, "Malformed request headers") if invalid_newline?(@buffer)
          raise Error.new(431, "Request headers are too large") if @buffer.bytesize >= max_bytes

          read_more(deadline, max_bytes - @buffer.bytesize)
        end
      end

      def read_line(max_bytes, deadline)
        loop do
          if (ending = @buffer.index("\r\n"))
            raise Error.new(400, "Request line is too large") if ending + 2 > max_bytes

            return consume(ending + 2).byteslice(0, ending)
          end

          ensure_before_deadline(deadline)
          raise Error.new(400, "Malformed request framing") if invalid_newline?(@buffer)
          raise Error.new(400, "Request line is too large") if @buffer.bytesize >= max_bytes

          read_more(deadline, max_bytes - @buffer.bytesize)
        end
      end

      def read_exact(bytes, deadline)
        while @buffer.bytesize < bytes
          ensure_before_deadline(deadline)
          read_more(deadline, bytes - @buffer.bytesize)
        end
        consume(bytes)
      end

      private

      def consume(bytes)
        result = @buffer.byteslice(0, bytes)
        @buffer = @buffer.byteslice(bytes, @buffer.bytesize - bytes) || +""
        result
      end

      def invalid_newline?(string)
        offset = 0
        while (newline = string.index("\n", offset))
          return true if newline.zero? || string.getbyte(newline - 1) != 13

          offset = newline + 1
        end
        false
      end

      def ensure_before_deadline(deadline)
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

        raise Error.new(408, "Request timed out")
      end

      def read_more(deadline, maximum)
        loop do
          ensure_before_deadline(deadline)
          result = @socket.read_nonblock([16 * 1024, maximum].min, exception: false)
          case result
          when :wait_readable
            wait_for_io(:read, deadline)
          when :wait_writable
            wait_for_io(:write, deadline)
          when nil, ""
            raise Error.new(400, "Unexpected end of request")
          else
            @buffer << result
            return
          end
        end
      rescue EOFError
        raise Error.new(400, "Unexpected end of request")
      end

      def wait_for_io(direction, deadline)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Error.new(408, "Request timed out") if remaining <= 0

        readers = direction == :read ? [@socket] : nil
        writers = direction == :write ? [@socket] : nil
        raise Error.new(408, "Request timed out") unless IO.select(readers, writers, nil, remaining)
      end
    end
  end
  private_constant :HTTPConnection
end
