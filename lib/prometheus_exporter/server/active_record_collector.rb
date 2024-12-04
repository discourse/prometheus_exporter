# frozen_string_literal: true

module PrometheusExporter::Server
  class ActiveRecordCollector < TypeCollector
    MAX_METRIC_AGE = 60

    ACTIVE_RECORD_GAUGES = {
      connections: "Total connections in pool",
      busy: "Connections in use in pool",
      dead: "Dead connections in pool",
      idle: "Idle connections in pool",
      waiting: "Connection requests waiting",
      size: "Maximum allowed connection pool size",
    }

    def initialize
      @active_record_metrics = MetricsContainer.new(ttl: MAX_METRIC_AGE)
      @active_record_metrics.filter = ->(new_metric, old_metric) do
        new_metric["pid"] == old_metric["pid"] &&
          new_metric["hostname"] == old_metric["hostname"] &&
          new_metric["metric_labels"]["pool_name"] == old_metric["metric_labels"]["pool_name"]
      end
    end

    def type
      "active_record"
    end

    def metrics
      return [] if @active_record_metrics.length == 0

      metrics = {}

      @active_record_metrics.map do |m|
        metric_key =
          (m["metric_labels"] || {}).merge("pid" => m["pid"], "hostname" => m["hostname"])
        metric_key.merge!(m["custom_labels"]) if m["custom_labels"]

        ACTIVE_RECORD_GAUGES.map do |k, help|
          k = k.to_s
          if v = m[k]
            g =
              metrics[k] ||= PrometheusExporter::Metric::Gauge.new(
                "active_record_connection_pool_#{k}",
                help,
              )
            g.observe(v, metric_key)
          end
        end
      end

      metrics.values
    end

    def collect(obj)
      @active_record_metrics << obj
    end
  end
end
