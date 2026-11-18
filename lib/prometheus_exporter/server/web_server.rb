# frozen_string_literal: true

require "logger"
require "stringio"
require "timeout"
require "zlib"
require_relative "http/basic_authenticator"
require_relative "http/server"

module PrometheusExporter::Server
  class WebServer
    attr_reader :collector

    PAGESIZE =
      begin
        `getconf PAGESIZE`.to_i
      rescue StandardError
        4096
      end
    private_constant :PAGESIZE

    ROUTE_METHODS = {
      "/metrics" => %w[GET HEAD OPTIONS].freeze,
      "/ping" => %w[GET HEAD OPTIONS].freeze,
      "/send-metrics" => %w[POST PUT OPTIONS].freeze,
    }.freeze
    ALL_METHODS = %w[GET HEAD POST PUT OPTIONS].freeze
    private_constant :ROUTE_METHODS, :ALL_METHODS

    NOT_FOUND_BODY =
      "Not Found! The Prometheus Ruby Exporter only listens on /ping, /metrics and /send-metrics"
    private_constant :NOT_FOUND_BODY

    def initialize(opts)
      @port = opts[:port] || PrometheusExporter::DEFAULT_PORT
      @bind = opts[:bind] || PrometheusExporter::DEFAULT_BIND_ADDRESS
      @timeout = opts[:timeout] || PrometheusExporter::DEFAULT_TIMEOUT
      @verbose = opts[:verbose] || false
      @auth = opts[:auth]
      @realm = opts[:realm] || PrometheusExporter::DEFAULT_REALM
      @pid = Process.pid

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

      @logger = build_logger(opts[:log_target])
      @logger.info("Using Basic Authentication via #{@auth}") if @verbose && @auth

      if %w[ALL ANY].include?(@bind)
        @logger.info("Listening on both 0.0.0.0/:: network interfaces")
        @bind = nil
      end

      @collector = opts[:collector] || Collector.new(logger: @logger)
      @authenticator =
        HTTP::BasicAuthenticator.new(path: @auth, realm: @realm, logger: @logger) if @auth

      @server =
        HTTP::Server.new(
          bind: @bind,
          port: @port,
          logger: @logger,
          max_clients: opts[:max_clients] || HTTP::Server::DEFAULT_MAX_CLIENTS,
          request_timeout: opts[:request_timeout] || HTTP::Server::DEFAULT_REQUEST_TIMEOUT,
          shutdown_timeout: opts[:shutdown_timeout] || HTTP::Server::DEFAULT_SHUTDOWN_TIMEOUT,
          write_timeout: opts[:write_timeout] || HTTP::Server::DEFAULT_WRITE_TIMEOUT,
          ssl_context: build_ssl_context(opts),
        ) { |request| route(request) }
    end

    def start
      @runner ||= @server.start
    rescue StandardError => e
      @logger.error("Failed to start prometheus collector web on port #{@port}: #{e}")
      raise
    end

    def stop
      @server.shutdown
      nil
    end

    def metrics
      metric_text = nil
      begin
        Timeout.timeout(@timeout) { metric_text = @collector.prometheus_metrics_text }
      rescue Timeout::Error
        @logger.error("Generating Prometheus metrics text timed out")
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

    private

    def build_logger(log_target)
      logger = Logger.new(log_target || (@verbose ? $stderr : File::NULL))
      logger.level = @verbose ? Logger::DEBUG : Logger::WARN
      logger
    end

    def build_ssl_context(opts)
      return unless opts[:tls_cert_file] && opts[:tls_key_file]

      require "openssl"

      context = OpenSSL::SSL::SSLContext.new
      context.cert = OpenSSL::X509::Certificate.new(File.read(opts[:tls_cert_file]))
      context.key = OpenSSL::PKey.read(File.read(opts[:tls_key_file]))
      context
    end

    def route(request)
      return options_response(ALL_METHODS) if request.method == "OPTIONS" && request.path == "*"
      if request.method == "CONNECT"
        response = HTTP::Response.new(status: 405, body: HTTP.status_message(405))
        response["Allow"] = ALL_METHODS.join(", ")
        return response
      end

      allowed_methods = ROUTE_METHODS[request.path]
      return HTTP::Response.new(status: 404, body: NOT_FOUND_BODY) unless allowed_methods
      if allowed_methods.none? { |method| method == request.method }
        response = HTTP::Response.new(status: 405, body: HTTP.status_message(405))
        response["Allow"] = allowed_methods.join(", ")
        return response
      end
      return options_response(allowed_methods) if request.method == "OPTIONS"

      case request.path
      when "/metrics"
        metrics_response(request)
      when "/send-metrics"
        handle_metrics(request)
      when "/ping"
        HTTP::Response.new(body: "PONG")
      end
    end

    def options_response(methods)
      response = HTTP::Response.new
      response["Allow"] = methods.join(", ")
      response
    end

    def metrics_response(request)
      if @authenticator && !@authenticator.authenticate(request["authorization"])
        response = HTTP::Response.new(status: 401, body: "Unauthorized")
        response["WWW-Authenticate"] = @authenticator.challenge
        return response
      end

      body = metrics
      response = HTTP::Response.new(body: body)
      if accepts_gzip?(request["accept-encoding"])
        response.body = gzip(body)
        response["Content-Encoding"] = "gzip"
      end
      response
    end

    def accepts_gzip?(header)
      gzip_quality = nil
      wildcard_quality = nil

      header
        .to_s
        .split(",")
        .each do |entry|
          coding, *parameters = entry.split(";").map!(&:strip)
          quality_parameter = parameters.find { |parameter| /\Aq=/i.match?(parameter) }
          quality = quality_parameter ? parse_quality(quality_parameter.split("=", 2).last) : 1.0
          gzip_quality = quality if coding.casecmp?("gzip")
          wildcard_quality = quality if coding == "*"
        end

      (gzip_quality.nil? ? wildcard_quality : gzip_quality).to_f.positive?
    end

    def parse_quality(value)
      quality = Float(value)
      (0.0..1.0).cover?(quality) ? quality : 0.0
    rescue ArgumentError, TypeError
      0.0
    end

    def gzip(body)
      output = StringIO.new
      writer = Zlib::GzipWriter.new(output)
      writer.write(body)
      writer.close
      output.string
    end

    def handle_metrics(request)
      @sessions_total.observe
      response = HTTP::Response.new(body: "OK")
      failed = false

      request.each_body_chunk do |chunk|
        next if failed

        begin
          @metrics_total.observe
          @collector.process(chunk)
        rescue StandardError => e
          @logger.error("\n\n#{e.inspect}\n#{e.backtrace}\n\n") if @verbose
          @bad_metrics_total.observe
          response.body = "Bad Metrics #{e}"
          response.status = exception_status(e)
          failed = true
        end
      end

      response
    end

    def exception_status(exception)
      return 500 unless exception.respond_to?(:status_code)

      status = exception.status_code
      return status if status.is_a?(Integer) && (100..599).cover?(status)
      if status.is_a?(String) && /\A\d{3}\z/.match?(status)
        status = status.to_i
        return status if (100..599).cover?(status)
      end

      500
    end
  end
end
