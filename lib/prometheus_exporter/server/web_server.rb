# frozen_string_literal: true

require 'webrick'
require 'timeout'
require 'zlib'
require 'stringio'

module PrometheusExporter::Server
  class WebServer
    attr_reader :collector

    def initialize(opts)
      @port = opts[:port] || PrometheusExporter::DEFAULT_PORT
      @bind = opts[:bind] || PrometheusExporter::DEFAULT_BIND_ADDRESS
      @collector = opts[:collector] || Collector.new
      @timeout = opts[:timeout] || PrometheusExporter::DEFAULT_TIMEOUT
      @verbose = opts[:verbose] || false
      @auth = opts[:auth]
      @realm = opts[:realm] || PrometheusExporter::DEFAULT_REALM

      @metrics_total = PrometheusExporter::Metric::Counter.new("collector_metrics_total", "Total metrics processed by exporter web.")

      @sessions_total = PrometheusExporter::Metric::Counter.new("collector_sessions_total", "Total send_metric sessions processed by exporter web.")

      @bad_metrics_total = PrometheusExporter::Metric::Counter.new("collector_bad_metrics_total", "Total mis-handled metrics by collector.")

      @metrics_total.observe(0)
      @sessions_total.observe(0)
      @bad_metrics_total.observe(0)

      @access_log, @logger = nil
      log_target = opts[:log_target]

      if @verbose
        @access_log = [
          [$stderr, WEBrick::AccessLog::COMMON_LOG_FORMAT],
          [$stderr, WEBrick::AccessLog::REFERER_LOG_FORMAT],
        ]
        @logger = WEBrick::Log.new(log_target || $stderr)
      else
        @access_log = []
        @logger = WEBrick::Log.new(log_target || "/dev/null")
      end

      @logger.info "Using Basic Authentication via #{@auth}" if @verbose && @auth

      if %w(ALL ANY).include?(@bind)
        @logger.info "Listening on both 0.0.0.0/:: network interfaces"
        @bind = nil
      end

      @server = WEBrick::HTTPServer.new(
        Port: @port,
        BindAddress: @bind,
        Logger: @logger,
        AccessLog: @access_log,
      )

      @server.mount_proc '/' do |req, res|
        res['Content-Type'] = 'text/plain; charset=utf-8'
        if req.path == '/metrics'
          authenticate(req, res) if @auth

          res.status = 200
          if req.header["accept-encoding"].to_s.include?("gzip")
            sio = StringIO.new
            collected_metrics = metrics
            begin
              writer = Zlib::GzipWriter.new(sio)
              writer.write(collected_metrics)
            ensure
              writer.close
            end
            res.body = sio.string
            res.header["content-encoding"] = "gzip"
          else
            res.body = metrics
          end
        elsif req.path == '/send-metrics'
          handle_metrics(req, res)
        elsif req.path == '/ping'
          res.body = 'PONG'
        else
          res.status = 404
          res.body = "Not Found! The Prometheus Ruby Exporter only listens on /ping, /metrics and /send-metrics"
        end
      end
    end

    def handle_metrics(req, res)
      @sessions_total.observe
      req.body do |block|
        begin
          @metrics_total.observe
          @collector.process(block)
        rescue => e
          if @verbose
            @logger.error "\n\n#{e.inspect}\n#{e.backtrace}\n\n"
          end
          @bad_metrics_total.observe
          res.body = "Bad Metrics #{e}"
          res.status = e.respond_to?(:status_code) ? e.status_code : 500
          return
        end
      end

      res.body = "OK"
      res.status = 200
    end

    def start
      @runner ||= Thread.start do
        begin
          @server.start
        rescue => e
          @logger.error "Failed to start prometheus collector web on port #{@port}: #{e}"
        end
      end
    end

    def stop
      @server.shutdown
    end

    def metrics
      metric_text = nil
      begin
        Timeout::timeout(@timeout) do
          metric_text = @collector.prometheus_metrics_text
        end
      rescue Timeout::Error
        # we timed out ... bummer
        @logger.error "Generating Prometheus metrics text timed out"
      end

      metrics = []

      metrics << add_gauge(
        "collector_working",
        "Is the master process collector able to collect metrics",
        metric_text && metric_text.length > 0 ? 1 : 0
      )

      metrics << add_gauge(
        "collector_rss",
        "total memory used by collector process",
        get_rss
      )

      metrics << @metrics_total
      metrics << @sessions_total
      metrics << @bad_metrics_total

      <<~TEXT
      #{metrics.map(&:to_prometheus_text).join("\n\n")}
      #{metric_text}
      TEXT
    end

    def get_rss
      @pagesize ||= `getconf PAGESIZE`.to_i rescue 4096
      @pid ||= Process.pid
      File.read("/proc/#{@pid}/statm").split(' ')[1].to_i * @pagesize rescue 0
    end

    def add_gauge(name, help, value)
      gauge = PrometheusExporter::Metric::Gauge.new(name, help)
      gauge.observe(value)
      gauge
    end

    def authenticate(req, res)
      htpasswd = WEBrick::HTTPAuth::Htpasswd.new(@auth)
      basic_auth = WEBrick::HTTPAuth::BasicAuth.new({ Realm: @realm, UserDB: htpasswd, Logger: @logger })

      basic_auth.authenticate(req, res)
    end

  end
end
