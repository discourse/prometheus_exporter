# frozen_string_literal: true
#
# This file contains logic derived from WEBrick request parsing.
# Copyright (c) 2000, 2001 TAKAHASHI Masayoshi, GOTOU Yuuzou.
# Copyright (c) 2002 Internet Programming with Ruby writers. All rights reserved.
# Vendored from WEBrick commit 25b0e9206bf5991c6274893d53c428d23b3f2292.
# See VENDORED_WEBRICK_LICENSE.txt for the BSD-2-Clause terms.

require "socket"
require "timeout"

module PrometheusExporter
  module Server
    module HTTP
      STATUS_MESSAGES = {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Request Entity Too Large",
        414 => "Request-URI Too Large",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        422 => "Unprocessable Entity",
        426 => "Upgrade Required",
        428 => "Precondition Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
      }.freeze
      UNKNOWN_STATUS_MESSAGE = "Unknown Status"

      def self.status_message(status)
        STATUS_MESSAGES.fetch(status, UNKNOWN_STATUS_MESSAGE)
      end

      class Error < StandardError
        attr_reader :status

        def initialize(status, message = nil)
          @status = status
          super(message || HTTP.status_message(status))
        end
      end

      class EndOfStream < StandardError
      end

      class Request
        MAX_REQUEST_LINE = 2083
        MAX_HEADER_LENGTH = 112 * 1024
        MAX_LINE_LENGTH = 4096
        INPUT_BUFFER_SIZE = 65_536
        BODY_METHODS = %w[POST PUT].freeze
        METHOD_TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
        REG_NAME =
          /\A(?=.{1,253}\z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*\z/

        attr_reader :headers, :http_version, :method, :path, :request_line, :target

        def initialize(socket, read_timeout:)
          @socket = socket
          @read_timeout = read_timeout
          @headers = nil
          @request_bytes = 0
          @body_complete = false
        end

        def parse
          read_request_line
          read_headers
          validate_host
          validate_framing
          self
        end

        def [](name)
          values = @headers[name.downcase]
          values.empty? ? nil : values.join(", ")
        end

        def keep_alive?
          connection = self["connection"].to_s.downcase.split(",").map!(&:strip)
          return false if connection.include?("close")

          @http_version == "1.1" || connection.include?("keep-alive")
        end

        def each_body_chunk(&block)
          return if @body_complete

          if self["transfer-encoding"]
            read_chunked(&block)
          elsif self["content-length"]
            read_fixed_length(Integer(self["content-length"], 10), &block)
          elsif BODY_METHODS.include?(@method)
            raise Error.new(411)
          else
            @body_complete = true
          end
        end

        def finish
          each_body_chunk { |_chunk| }
        end

        private

        def read_request_line
          @request_line = read_line(MAX_REQUEST_LINE)
          raise EndOfStream unless @request_line

          @request_bytes = @request_line.bytesize
          if @request_bytes >= MAX_REQUEST_LINE && !@request_line.end_with?("\n")
            raise Error.new(414)
          end

          match = %r{\A(\S+) (\S++) HTTP/(\d+\.\d+)\r\n\z}m.match(@request_line)
          raise Error.new(400, "bad Request-Line") unless match

          @method, @target, @http_version = match.captures
          raise Error.new(400, "invalid method token") unless METHOD_TOKEN.match?(@method)
          raise Error.new(505) if %w[1.0 1.1].none? { |version| version == @http_version }

          @path = extract_path(@target)
        end

        def extract_path(target)
          if target == "*"
            raise Error.new(400, "bad request target") unless @method == "OPTIONS"

            return target
          end

          if @method == "CONNECT"
            unless valid_authority?(target, require_port: true)
              raise Error.new(400, "bad CONNECT target")
            end

            return target
          end

          raw_path =
            if target.start_with?("/")
              target.split("?", 2).first
            elsif (match = %r{\Ahttps?://([^/]+)(/[^#]*)?\z}i.match(target))
              raise Error.new(400, "bad request target") unless valid_authority?(match[1])

              (match[2] || "/").split("?", 2).first
            else
              raise Error.new(400, "bad request target")
            end

          raise Error.new(400, "bad request target") if /%(?![0-9a-fA-F]{2})/.match?(raw_path)

          raw_path.gsub(/%([0-9a-fA-F]{2})/) { $1.to_i(16).chr }
        end

        def read_headers(trailers: false)
          lines = []
          complete = false

          while (line = read_line)
            if line == "\r\n"
              complete = true
              break
            end

            @request_bytes += line.bytesize
            raise Error.new(413, "headers too large") if @request_bytes > MAX_HEADER_LENGTH
            raise Error.new(400, "null byte in header") if line.include?("\0")

            lines << line
          end

          raise Error.new(400, "incomplete headers") unless complete

          parsed = parse_headers(lines)
          @headers = parsed unless trailers
          nil
        end

        def parse_headers(lines)
          header = Hash.new([].freeze)
          field = nil

          lines.each do |line|
            if (match = /\A([A-Za-z0-9!#$%&'*+\-.^_`|~]+):([^\r\n\0]*?)\r\n\z/m.match(line))
              field = match[1].downcase
              header[field] = [] unless header.key?(field)
              header[field] << match[2]
            elsif (match = /\A[ \t]+([^\r\n\0]*?)\r\n\z/m.match(line))
              raise Error.new(400, "bad header") unless field

              header[field][-1] << " " << match[1]
            else
              raise Error.new(400, "bad header")
            end
          end

          header.each_value do |values|
            values.each do |value|
              value.sub!(/\A[ \t]+/, "")
              value.sub!(/[ \t]+\z/, "")
            end
          end
          header
        end

        def validate_host
          hosts = @headers["host"]
          if @http_version == "1.1" && hosts.empty?
            raise Error.new(400, "missing Host request header")
          end
          return if hosts.empty?

          if hosts.length != 1 || !valid_authority?(hosts.first)
            raise Error.new(400, "invalid Host request header")
          end
        end

        def valid_authority?(authority, require_port: false)
          host = nil
          port = nil

          if authority.start_with?("[")
            match = /\A\[([^\]]+)\](?::(\d+))?\z/.match(authority)
            return false unless match

            return false unless valid_ipv6_address?(match[1])

            host = match[1]
            port = match[2]
          else
            if authority.count(":") > 1
              return false if require_port

              return valid_ipv6_address?(authority)
            end

            host, separator, port = authority.rpartition(":")
            if separator.empty?
              host = authority
              port = nil
            end
            return false unless REG_NAME.match?(host)
          end

          return false if host.empty? || (require_port && port.nil?)
          return true if port.nil?

          /\A\d+\z/.match?(port) && port.to_i <= 65_535
        end

        def valid_ipv6_address?(address)
          flags = Socket.const_defined?(:AI_NUMERICHOST) ? Socket::AI_NUMERICHOST : 0
          Addrinfo.getaddrinfo(address, nil, Socket::AF_INET6, Socket::SOCK_STREAM, 0, flags)
          true
        rescue SocketError
          false
        end

        def validate_framing
          content_lengths = @headers["content-length"]
          unless content_lengths.empty?
            if content_lengths.length > 1
              raise Error.new(400, "multiple content-length request headers")
            end
            unless /\A\d+\z/.match?(content_lengths.first)
              raise Error.new(400, "invalid content-length request header")
            end
          end

          transfer_encoding = self["transfer-encoding"]
          return unless transfer_encoding

          if self["content-length"]
            raise Error.new(
                    400,
                    "request with both transfer-encoding and content-length, possible request smuggling",
                  )
          end
          unless /\Achunked\z/i.match?(transfer_encoding)
            raise Error.new(501, "unsupported transfer-encoding")
          end
        end

        def read_fixed_length(remaining)
          while remaining > 0
            size = [remaining, INPUT_BUFFER_SIZE].min
            data = read_data(size)
            raise Error.new(400, "invalid body size") unless data&.bytesize == size

            remaining -= data.bytesize
            yield data
          end
          @body_complete = true
        end

        def read_chunked
          chunk_size = read_chunk_size
          while chunk_size > 0
            remaining = chunk_size
            while remaining > 0
              size = [remaining, INPUT_BUFFER_SIZE].min
              data = read_data(size)
              raise Error.new(400, "bad chunk data size") unless data&.bytesize == size

              yield data
              remaining -= size
            end

            raise Error.new(400, "extra data after chunk") unless read_line == "\r\n"

            chunk_size = read_chunk_size
          end

          # WEBrick master selectively imports requested, non-sensitive trailers.
          # This focused server does not use trailers, so it validates their syntax
          # and framing but safely discards every trailer field.
          read_headers(trailers: true)
          @body_complete = true
        end

        def read_chunk_size
          line = read_line
          raise Error.new(400, "bad chunk") unless line

          match = /\A([0-9a-fA-F]+)(?:;(\S+(?:=\S+)?))?\r\n\z/.match(line)
          raise Error.new(400, "bad chunk") unless match

          match[1].to_i(16)
        end

        def read_line(limit = MAX_LINE_LENGTH)
          timed_read { @socket.gets("\n", limit) }
        end

        def read_data(size)
          timed_read { @socket.read(size) }
        end

        def timed_read
          Timeout.timeout(@read_timeout) { yield }
        rescue Timeout::Error
          raise Error.new(408)
        rescue EOFError, Errno::ECONNRESET, Errno::ECONNABORTED, IOError
          nil
        end
      end

      class Response
        attr_accessor :body, :status
        attr_reader :headers

        def initialize(status: 200, body: "")
          @status = status
          @body = body
          @headers = {}
        end

        def []=(name, value)
          @headers[name] = value
        end
      end
    end
  end
end
