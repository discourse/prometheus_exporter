# frozen_string_literal: true

require 'webrick'
require 'timeout'

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
          res.body = metrics
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

      <<~TEXT
      #{@metrics.map(&:to_prometheus_text).join("\n\n")}
      #{metric_text}
      TEXT
    end

    def add_gauge(name, help, value)
      gauge = PrometheusExporter::Metric::Gauge.new(name, help)
      gauge.observe(value)
      @metrics << gauge
    end

  end
end
