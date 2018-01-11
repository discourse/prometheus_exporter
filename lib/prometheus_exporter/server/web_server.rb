# frozen_string_literal: true

require 'webrick'
require 'timeout'
require 'zlib'
require 'stringio'

module PrometheusExporter::Server
  class WebServer
    attr_reader :collector

    def initialize(port: , collector: nil)

      @server = WEBrick::HTTPServer.new(
        Port: port,
        AccessLog: [],
        Logger: WEBrick::Log.new("/dev/null")
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
          res.body = "Not Found! The Prometheus Discourse plugin only listens on /metrics and /send-metrics"
        end
      end
    end

    def handle_metrics(req, res)
      req.body do |block|
        begin
          @collector.process(JSON.parse(block))
        rescue => e
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

      @metrics = []

      add_gauge(
        "collector_working",
        "Is the master process collector able to collect metrics",
        metric_text && metric_text.length > 0 ? 1 : 0
      )

      add_gauge(
        "collector_rss",
        "total memory used by collector process",
        get_rss
      )

      <<~TEXT
      #{@metrics.map(&:to_prometheus_text).join("\n\n")}
      #{metric_text}
      TEXT
    end

    def get_rss
      @pagesize ||= `getconf PAGESIZE`.to_i rescue 4096
      File.read("/proc/#{pid}/statm").split(' ')[1].to_i * @pagesize rescue 0
    end

    def add_gauge(name, help, value)
      gauge = PrometheusExporter::Metric::Gauge.new(name, help)
      gauge.observe(value)
      @metrics << gauge
    end

  end
end
