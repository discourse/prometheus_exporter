# frozen_string_literal: true

require "logger"
require "openssl"
require "puma"
require "puma/server"
require "stringio"
require "timeout"
require "uri"
require "zlib"

module PrometheusExporter::Server
  class WebServer
    PAGESIZE =
      begin
        `getconf PAGESIZE`.to_i
      rescue StandardError
        4096
      end
    private_constant :PAGESIZE

    DEFAULT_MAX_RECORD_SIZE = 1024 * 1024

    NOT_FOUND =
      "Not Found! The Prometheus Ruby Exporter only listens on /ping, /metrics and /send-metrics"
    private_constant :NOT_FOUND

    attr_reader :collector, :port

    def initialize(opts)
      @port = opts[:port] || PrometheusExporter::DEFAULT_PORT
      @bind = opts[:bind] || PrometheusExporter::DEFAULT_BIND_ADDRESS
      @timeout = opts[:timeout] || PrometheusExporter::DEFAULT_TIMEOUT
      @verbose = opts[:verbose] || false
      @auth = opts[:auth]
      @realm = opts[:realm] || PrometheusExporter::DEFAULT_REALM
      @max_record_size = positive_integer(opts.fetch(:max_record_size, DEFAULT_MAX_RECORD_SIZE))
      @tls_cert_file = opts[:tls_cert_file]
      @tls_key_file = opts[:tls_key_file]
      @pid = Process.pid
      @stopped = false

      validate_options!
      build_self_metrics
      build_loggers(opts[:log_target])
      @logger.info "Using Basic Authentication via #{@auth}" if @verbose && @auth
      @collector = opts[:collector] || Collector.new(logger: @logger)
    end

    def call(env)
      log_request(env)

      case env["PATH_INFO"]
      when "/metrics"
        metrics_response(env)
      when "/send-metrics"
        handle_metrics(env)
      when "/ping"
        response(200, "PONG")
      else
        response(404, NOT_FOUND)
      end
    end

    def start
      return @runner if @runner&.alive?
      raise "prometheus collector web server has been stopped" if @stopped

      begin
        @server =
          Puma::Server.new(
            self,
            nil,
            log_writer: @puma_log_writer,
            environment: "production",
            http_content_length_limit: @max_record_size,
          )
        @server.binder.parse(bind_uris)
        @port = @server.binder.connected_ports.first
        @runner = @server.run(true, thread_name: "prometheus-exporter")
      rescue => e
        @logger&.error "Failed to start prometheus collector web on port #{@port}: #{e}"
        @server&.binder&.close
        @server = @runner = nil
        raise
      end
    end

    def stop
      return if @stopped

      @server&.stop(true)
    ensure
      @server = @runner = nil
      @stopped = true
      close_owned_log
    end

    def metrics
      metric_text = nil
      begin
        Timeout.timeout(@timeout) { metric_text = @collector.prometheus_metrics_text }
      rescue Timeout::Error
        @logger.error "Generating Prometheus metrics text timed out"
      end

      self_metrics = [
        add_gauge(
          "collector_working",
          "Is the master process collector able to collect metrics",
          metric_text && metric_text.length > 0 ? 1 : 0,
        ),
        add_gauge("collector_rss", "total memory used by collector process", get_rss),
        @metrics_total,
        @sessions_total,
        @bad_metrics_total,
      ]

      <<~TEXT
        #{self_metrics.map(&:to_prometheus_text).join("\n\n")}
        #{metric_text}
      TEXT
    end

    def get_rss
      File.read("/proc/#{@pid}/statm").split(" ")[1].to_i * PAGESIZE
    rescue StandardError
      0
    end

    def add_gauge(name, help, value)
      gauge = PrometheusExporter::Metric::Gauge.new(name, help)
      gauge.observe(value)
      gauge
    end

    private

    def positive_integer(value)
      value = Integer(value)
      raise ArgumentError if value <= 0

      value
    rescue TypeError, ArgumentError
      raise ArgumentError, "max_record_size must be larger than 0"
    end

    def validate_options!
      if @tls_cert_file.nil? != @tls_key_file.nil?
        raise ArgumentError, "tls_cert_file and tls_key_file must be configured together"
      end
      if @realm.to_s.match?(/[\x00-\x1f\x7f]/)
        raise ArgumentError, "realm must not contain control characters"
      end
    end

    def bind_uris
      scheme = @tls_cert_file ? "ssl" : "tcp"
      ["#{scheme}://#{bind_host}:#{@port}#{ssl_query}"]
    end

    def bind_host
      return "[::]" if %w[ALL ANY].include?(@bind)
      return "localhost" if @bind == "localhost"

      @bind.include?(":") && !@bind.start_with?("[") ? "[#{@bind}]" : @bind
    end

    def ssl_query
      return "" unless @tls_cert_file

      "?#{URI.encode_www_form(cert: @tls_cert_file, key: @tls_key_file, verify_mode: "none")}"
    end

    def build_self_metrics
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

      [@metrics_total, @sessions_total, @bad_metrics_total].each { |metric| metric.observe(0) }
    end

    def build_loggers(log_target)
      @log_io =
        if log_target.respond_to?(:write)
          log_target
        elsif log_target
          @owns_log_io = true
          File.open(log_target, "a")
        elsif @verbose
          $stderr
        else
          @owns_log_io = true
          File.open(File::NULL, "w")
        end
      @puma_log_writer = Puma::LogWriter.new(@log_io, @log_io)
      @logger = Logger.new(@log_io)
      @log_enabled = @verbose || !log_target.nil?
    end

    def close_owned_log
      return unless @owns_log_io && @log_io && !@log_io.closed?

      @logger&.close
    rescue IOError, SystemCallError
      nil
    end

    def metrics_response(env)
      return unauthorized_response unless authenticated?(env)

      body = metrics
      headers = { "Vary" => "Accept-Encoding" }
      if accepts_gzip?(env["HTTP_ACCEPT_ENCODING"])
        output = StringIO.new
        writer = Zlib::GzipWriter.new(output)
        begin
          writer.write(body)
        ensure
          writer.close
        end
        body = output.string
        headers["Content-Encoding"] = "gzip"
      end

      response(200, body, headers)
    end

    def accepts_gzip?(header)
      header.to_s.downcase.include?("gzip")
    end

    def handle_metrics(env)
      unless env["REQUEST_METHOD"] == "POST"
        return response(405, "Method Not Allowed", "Allow" => "POST")
      end

      @sessions_total.observe
      @metrics_total.observe
      @collector.process(env["rack.input"].read)
      response(200, "OK")
    rescue => e
      @logger.error "\n\n#{e.inspect}\n#{e.backtrace}\n\n" if @log_enabled
      @bad_metrics_total.observe
      status = e.respond_to?(:status_code) ? e.status_code : 500
      response(status, "Bad Metrics #{e}")
    end

    def response(status, body, headers = {})
      [status, { "Content-Type" => "text/plain; charset=utf-8" }.merge(headers), [body]]
    end

    def authenticated?(env)
      return true unless @auth

      scheme, encoded = env["HTTP_AUTHORIZATION"].to_s.split(" ", 2)
      return false unless scheme&.casecmp?("Basic") && encoded

      user, password = encoded.unpack1("m0").split(":", 2)
      return false unless user && password

      File.foreach(@auth) do |line|
        stored_user, password_hash = line.chomp.split(":", 2)
        next unless stored_user == user && password_hash

        return OpenSSL.secure_compare(password.crypt(password_hash), password_hash)
      end
      false
    rescue ArgumentError, Errno::ENOENT
      false
    end

    def unauthorized_response
      realm = @realm.to_s.gsub(/["\\]/) { |character| "\\#{character}" }
      response(401, "Unauthorized", "WWW-Authenticate" => %(Basic realm="#{realm}"))
    end

    def log_request(env)
      return unless @verbose

      @logger.info %(#{env["REMOTE_ADDR"]} "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]} #{env["SERVER_PROTOCOL"]}")
    end
  end
end
