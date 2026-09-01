# frozen_string_literal: true

require "logger"
require "stringio"
require "timeout"
require "zlib"

require_relative "socket_listener"

module PrometheusExporter::Server
  # Exporter application facade. It owns routes, metrics, authentication, and
  # compression while delegating bounded HTTP and socket work to internal units.
  class WebServer
    MAX_REQUEST_LINE_BYTES = 8 * 1024
    MAX_HEADER_LINE_BYTES = 8 * 1024
    MAX_HEADER_BYTES = 64 * 1024
    MAX_HEADER_COUNT = 100
    MAX_BODY_CHUNK_BYTES = 1024 * 1024
    DEFAULT_MAX_CONNECTIONS = 100
    DEFAULT_HEADER_TIMEOUT = 5
    DEFAULT_BODY_READ_TIMEOUT = 30
    DEFAULT_WRITE_TIMEOUT = 5
    DEFAULT_STOP_TIMEOUT = 1

    PAGESIZE =
      begin
        `getconf PAGESIZE`.to_i
      rescue StandardError
        4096
      end
    private_constant :PAGESIZE

    attr_reader :collector

    def initialize(opts)
      @port = opts[:port] || PrometheusExporter::DEFAULT_PORT
      @bind = opts[:bind] || PrometheusExporter::DEFAULT_BIND_ADDRESS
      @timeout = opts[:timeout] || PrometheusExporter::DEFAULT_TIMEOUT
      @header_timeout = opts.fetch(:header_timeout, DEFAULT_HEADER_TIMEOUT)
      @body_read_timeout = opts.fetch(:body_read_timeout, DEFAULT_BODY_READ_TIMEOUT)
      @write_timeout = opts.fetch(:write_timeout, DEFAULT_WRITE_TIMEOUT)
      @stop_timeout = opts.fetch(:stop_timeout, DEFAULT_STOP_TIMEOUT)
      @max_connections = opts.fetch(:max_connections, DEFAULT_MAX_CONNECTIONS)
      validate_options(opts)

      @verbose = opts[:verbose] || false
      @auth = opts[:auth]
      @realm = opts[:realm] || PrometheusExporter::DEFAULT_REALM
      @pid = Process.pid
      initialize_metrics

      log_target = opts[:log_target] || (@verbose ? $stderr : File::NULL)
      @logger = Logger.new(log_target)
      @logger.info "Using Basic Authentication via #{@auth}" if @verbose && @auth

      if %w[ALL ANY].include?(@bind)
        @logger.info "Listening on both 0.0.0.0/:: network interfaces" if @verbose
        @bind = nil
      end

      @collector = opts[:collector] || Collector.new(logger: @logger)
      @listener =
        SocketListener.new(
          port: @port,
          bind: @bind,
          tls_cert_file: opts[:tls_cert_file],
          tls_key_file: opts[:tls_key_file],
          max_connections: @max_connections,
          timeouts: {
            header: @header_timeout,
            body_read: @body_read_timeout,
            write: @write_timeout,
            stop: @stop_timeout,
          },
          limits: {
            request_line: MAX_REQUEST_LINE_BYTES,
            header_line: MAX_HEADER_LINE_BYTES,
            headers: @max_header_bytes,
            header_count: MAX_HEADER_COUNT,
            body_chunk: @max_body_chunk_bytes,
          },
          logger: @logger,
          verbose: @verbose,
          request_handler: method(:route),
        )
    end

    def start
      @listener.start
    end

    def stop
      @listener.stop
    end

    def accept_error
      @listener.accept_error
    end

    # Retained for callers which used WebServer#handle_metrics with a request
    # object exposing WEBrick's streaming #body API.
    def handle_metrics(req, res)
      @sessions_total.observe
      failed = false
      req.body do |chunk|
        begin
          process_metrics_chunk(chunk)
        rescue => e
          failed = true
          log_collector_error(e)
          res.body = "Bad Metrics #{e}"
          res.status = collector_error_status(e)
          break
        end
      end

      unless failed
        res.body = "OK"
        res.status = 200
      end
    end

    def metrics
      metric_text = nil
      begin
        Timeout.timeout(@timeout) { metric_text = @collector.prometheus_metrics_text }
      rescue Timeout::Error
        @logger.error "Generating Prometheus metrics text timed out"
      end

      metrics = []
      metrics << add_gauge(
        "collector_working",
        "Is the master process collector able to collect metrics",
        metric_text && metric_text.length > 0 ? 1 : 0,
      )
      metrics << add_gauge("collector_rss", "total memory used by collector process", get_rss)
      metrics << @metrics_total
      metrics << @sessions_total
      metrics << @bad_metrics_total

      <<~TEXT
      #{metrics.map(&:to_prometheus_text).join("\n\n")}
      #{metric_text}
      TEXT
    end

    def get_rss
      begin
        File.read("/proc/#{@pid}/statm").split(" ")[1].to_i * PAGESIZE
      rescue StandardError
        0
      end
    end

    def add_gauge(name, help, value)
      gauge = PrometheusExporter::Metric::Gauge.new(name, help)
      gauge.observe(value)
      gauge
    end

    # Retained for compatibility with request/response objects that provide the
    # small subset of WEBrick's header API used here.
    def authenticate(req, res)
      authorization = Array(req.header["authorization"]).first
      return true if valid_authorization?(authorization)

      res.status = 401
      res.body = "Unauthorized"
      res["WWW-Authenticate"] = basic_auth_challenge if res.respond_to?(:[]=)
      false
    end

    private

    def validate_options(opts)
      {
        header_timeout: @header_timeout,
        body_read_timeout: @body_read_timeout,
        write_timeout: @write_timeout,
        stop_timeout: @stop_timeout,
      }.each do |name, value|
        unless value.is_a?(Numeric) && value.finite? && value.positive?
          raise ArgumentError, "#{name} must be a positive number"
        end
      end

      @max_header_bytes = opts.fetch(:max_header_bytes, MAX_HEADER_BYTES)
      @max_body_chunk_bytes = opts.fetch(:max_body_chunk_bytes, MAX_BODY_CHUNK_BYTES)
      {
        max_connections: @max_connections,
        max_header_bytes: @max_header_bytes,
        max_body_chunk_bytes: @max_body_chunk_bytes,
      }.each do |name, value|
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "#{name} must be a positive integer"
        end
      end
    end

    def initialize_metrics
      @metrics_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_metrics_total",
          "Total metrics processed by exporter web.",
        )
      @sessions_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_sessions_total",
          "Total send_metric sessions processed by exporter web.",
        )
      @bad_metrics_total =
        PrometheusExporter::Metric::Counter.new(
          "collector_bad_metrics_total",
          "Total mis-handled metrics by collector.",
        )

      @metrics_total.observe(0)
      @sessions_total.observe(0)
      @bad_metrics_total.observe(0)
    end

    def route(request, connection)
      case request.path
      when "/metrics"
        require_method(request, "GET")
        connection.reject_body(request)
        return unauthorized_response unless valid_authorization?(request.headers["authorization"])

        metrics_response(request)
      when "/ping"
        require_method(request, "GET")
        connection.reject_body(request)
        [200, "PONG", {}]
      when "/send-metrics"
        require_method(request, "POST")
        receive_metrics(request, connection)
      else
        [
          404,
          "Not Found! The Prometheus Ruby Exporter only listens on /ping, /metrics and /send-metrics",
          {},
        ]
      end
    end

    def metrics_response(request)
      body = metrics
      headers = { "Vary" => "Accept-Encoding" }
      if accepts_gzip?(request.headers["accept-encoding"])
        body = gzip(body)
        headers["Content-Encoding"] = "gzip"
      end
      [200, body, headers]
    end

    def require_method(request, expected)
      return if request.method == expected

      raise HTTPConnection::Error.new(405, "Method Not Allowed", { "Allow" => expected })
    end

    def receive_metrics(request, connection)
      @sessions_total.observe
      connection.each_body_chunk(request) { |chunk| process_metrics_chunk(chunk) }
      [200, "OK", {}]
    rescue HTTPConnection::Error
      raise
    rescue => e
      log_collector_error(e)
      raise HTTPConnection::Error.new(collector_error_status(e), "Bad Metrics #{e}")
    end

    def process_metrics_chunk(chunk)
      @metrics_total.observe
      @collector.process(chunk)
    rescue => e
      @bad_metrics_total.observe
      raise e
    end

    def log_collector_error(error)
      @logger.error "\n\n#{error.inspect}\n#{Array(error.backtrace).join("\n")}\n\n" if @verbose
    end

    def collector_error_status(error)
      status = error.status_code if error.respond_to?(:status_code)
      status.is_a?(Integer) && status.between?(400, 599) ? status : 500
    rescue StandardError
      500
    end

    def unauthorized_response
      return 200, nil, {} unless @auth

      [401, "Unauthorized", { "WWW-Authenticate" => basic_auth_challenge }]
    end

    def valid_authorization?(authorization)
      return true unless @auth

      scheme, encoded = authorization.to_s.split(" ", 2)
      return false unless scheme&.casecmp?("Basic") && encoded && !encoded.include?(" ")

      decoded = encoded.unpack1("m0")
      username, password = decoded.split(":", 2)
      return false unless username && password

      File.foreach(@auth) do |line|
        entry_user, password_hash = line.chomp.split(":", 2)
        next unless entry_user == username && password_hash && !password_hash.empty?

        password_hash = password_hash.delete_prefix("{CRYPT}")
        candidate = password.crypt(password_hash)
        return secure_compare(candidate, password_hash)
      end
      false
    rescue ArgumentError, Errno::EINVAL, SystemCallError
      false
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      result = 0
      left.bytes.zip(right.bytes) { |a, b| result |= a ^ b }
      result.zero?
    end

    def basic_auth_challenge
      realm = @realm.to_s.gsub(/[\x00-\x1f\x7f]/, "").gsub(/["\\]/) { |character| "\\#{character}" }
      %(Basic realm="#{realm}")
    end

    def accepts_gzip?(header)
      return false unless header

      qualities = Hash.new { |hash, coding| hash[coding] = [] }
      header
        .split(",", -1)
        .each do |entry|
          coding, *parameters = entry.strip.split(";", -1)
          coding = coding&.strip
          next unless coding&.match?(/\A(?:[!#$%&'*+\-.^_`|~0-9A-Za-z]+|\*)\z/n)

          quality = parse_encoding_quality(parameters)
          qualities[coding.downcase] << quality if quality
        end

      explicit = qualities["gzip"]
      quality = explicit.empty? ? qualities["*"].max : explicit.max
      !!(quality && quality.positive?)
    end

    def parse_encoding_quality(parameters)
      return 1.0 if parameters.empty?
      return unless parameters.length == 1

      match = /\Aq[ \t]*=[ \t]*(0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?)\z/i.match(parameters.first.strip)
      match && match[1].to_f
    end

    def gzip(body)
      output = StringIO.new
      writer = Zlib::GzipWriter.new(output)
      writer.write(body)
      writer.close
      output.string
    end
  end
end
