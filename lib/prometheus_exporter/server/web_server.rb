# frozen_string_literal: true

require "logger"
require "openssl"
require "timeout"
require "async/http/server"
require "async/http/endpoint"
require "protocol/http/response"
require "protocol/http/body/buffered"
require "protocol/http/content_encoding"

module PrometheusExporter::Server
  class WebServer
    PAGESIZE =
      begin
        `getconf PAGESIZE`.to_i
      rescue StandardError
        4096
      end
    private_constant :PAGESIZE

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
      @tls_cert_file = opts[:tls_cert_file]
      @tls_key_file = opts[:tls_key_file]
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

      log_target = opts[:log_target] || (@verbose ? $stderr : File::NULL)
      @logger = Logger.new(log_target)
      @logger.level = Logger::INFO
      @logger.info "Using Basic Authentication via #{@auth}" if @verbose && @auth

      @collector = opts[:collector] || Collector.new(logger: @logger)
    end

    def call(request)
      log_request(request)

      case request.path.split("?", 2).first
      when "/metrics"
        metrics_response(request)
      when "/send-metrics"
        handle_metrics(request)
      when "/ping"
        text_response(200, "PONG")
      else
        text_response(404, NOT_FOUND)
      end
    end

    def start
      return @thread if @thread&.alive?

      url, options = endpoint_args
      endpoint = Async::HTTP::Endpoint.parse(url, **options)
      app = Protocol::HTTP::ContentEncoding.new(self)
      server = Async::HTTP::Server.new(app, endpoint)

      bound = Queue.new
      @thread =
        Thread.new do
          begin
            Async do |task|
              @scheduler = Fiber.scheduler
              endpoint.accept(&server.method(:accept))
              bound << :bound
              task.children.each(&:wait)
            end
          rescue => e
            bound << e
          end
        end

      result = bound.pop
      if result.is_a?(Exception)
        @logger.error "Failed to start prometheus collector web on port #{@port}: #{result}"
        @thread = nil
        @scheduler = nil
        raise result
      end

      @thread
    end

    def stop
      @scheduler&.interrupt
      @thread&.join
    ensure
      @thread = nil
      @scheduler = nil
    end

    def metrics
      metric_text = nil
      begin
        Timeout.timeout(@timeout) { metric_text = @collector.prometheus_metrics_text }
      rescue Timeout::Error
        # we timed out ... bummer
        @logger.error "Generating Prometheus metrics text timed out"
      end

      self_metrics = []

      self_metrics << add_gauge(
        "collector_working",
        "Is the master process collector able to collect metrics",
        metric_text && metric_text.length > 0 ? 1 : 0,
      )

      self_metrics << add_gauge("collector_rss", "total memory used by collector process", get_rss)

      self_metrics << @metrics_total
      self_metrics << @sessions_total
      self_metrics << @bad_metrics_total

      <<~TEXT
      #{self_metrics.map(&:to_prometheus_text).join("\n\n")}
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

    def handle_metrics(request)
      @sessions_total.observe

      request.body&.each do |chunk|
        begin
          @metrics_total.observe
          @collector.process(chunk)
        rescue => e
          @logger.error "\n\n#{e.inspect}\n#{e.backtrace}\n\n" if @verbose
          @bad_metrics_total.observe
        end
      end

      text_response(200, "OK")
    end

    def metrics_response(request)
      return unauthorized_response unless authenticated?(request)

      text_response(200, metrics)
    end

    def text_response(status, body)
      Protocol::HTTP::Response[status, { "content-type" => "text/plain; charset=utf-8" }, [body]]
    end

    def authenticated?(request)
      return true unless @auth

      scheme, encoded = request.headers["authorization"]&.credentials
      return false unless scheme&.casecmp?("Basic") && encoded

      user, password = encoded.unpack1("m0").to_s.split(":", 2)
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
      Protocol::HTTP::Response[
        401,
        {
          "content-type" => "text/plain; charset=utf-8",
          "www-authenticate" => %(Basic realm="#{realm}"),
        },
        ["Unauthorized"]
      ]
    end

    def endpoint_args
      host = @bind

      if %w[ALL ANY].include?(host)
        @logger.info "Listening on both 0.0.0.0/:: network interfaces"
        host = "::"
      end

      host = "[#{host}]" if host.include?(":")

      if @tls_cert_file && @tls_key_file
        ["https://#{host}:#{@port}", { ssl_context: build_ssl_context }]
      else
        ["http://#{host}:#{@port}", {}]
      end
    end

    def build_ssl_context
      context = OpenSSL::SSL::SSLContext.new
      context.cert = OpenSSL::X509::Certificate.new(File.read(@tls_cert_file))
      context.key = OpenSSL::PKey.read(File.read(@tls_key_file))
      context
    end

    def log_request(request)
      return unless @verbose

      @logger.info "#{request.method} #{request.path}"
    end
  end
end
