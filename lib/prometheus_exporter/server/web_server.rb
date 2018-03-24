# frozen_string_literal: true

require 'webrick'
require 'timeout'
require 'zlib'
require 'stringio'

module PrometheusExporter::Server
  class WebServer
    attr_reader :collector

    def initialize(port: , collector: nil, verbose: false)

      @verbose = verbose

      @total_metrics = PrometheusExporter::Metric::Counter.new("collector_metrics_total", "Total metrics processed by exporter web.")

      @total_sessions = PrometheusExporter::Metric::Counter.new("collector_sessions_total", "Total send_metric sessions processed by exporter web.")

      @total_bad_metrics = PrometheusExporter::Metric::Counter.new("collector_bad_metrics_total", "Total mis-handled metrics by collector.")

      @total_metrics.observe(0)
      @total_sessions.observe(0)
      @total_bad_metrics.observe(0)

      access_log, logger = nil

      if verbose
        access_log = [
          [$stderr, WEBrick::AccessLog::COMMON_LOG_FORMAT],
          [$stderr, WEBrick::AccessLog::REFERER_LOG_FORMAT],
        ]
        logger = WEBrick::Log.new($stderr)
      else
        access_log = []
        logger = WEBrick::Log.new("/dev/null")
      end

      @server = WEBrick::HTTPServer.new(
        Port: port,
        Logger: logger,
        AccessLog: access_log,
      )

      @collector = collector || Collector.new
      @port = port

      @server.mount_proc '/' do |req, res|
        res['ContentType'] = 'text/plain; charset=utf-8'
        if req.path == '/metrics'
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
        else
          res.status = 404
          res.body = "Not Found! The Prometheus Ruby Exporter only listens on /metrics and /send-metrics"
        end
      end
    end

    def handle_metrics(req, res)
      @total_sessions.observe
      req.body do |block|
        begin
          @total_metrics.observe
          @collector.process(block)
        rescue => e
          if @verbose
            STDERR.puts
            STDERR.puts e.inspect
            STDERR.puts e.backtrace
            STDERR.puts
          end
          @total_bad_metrics.observe
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
          STDERR.puts "Failed to start prometheus collector web on port #{@port}: #{e}"
        end
      end
    end

    def stop
      @server.shutdown
    end

    def metrics
      metric_text = nil
      begin
        Timeout::timeout(2) do
          metric_text = @collector.prometheus_metrics_text
        end
      rescue Timeout::Error
        # we timed out ... bummer
        STDERR.puts "Generating Prometheus metrics text timed out"
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

      metrics << @total_metrics
      metrics << @total_sessions
      metrics << @total_bad_metrics

      <<-TEXT
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

  end
end
