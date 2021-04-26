# frozen_string_literal: true

module PrometheusExporter::Server
  class ActiveRecordCollector < TypeCollector
    MAX_ACTIVERECORD_METRIC_AGE = 60
    ACTIVE_RECORD_GAUGES = {
      connections: "Total connections in pool",
      busy: "Connections in use in pool",
      dead: "Dead connections in pool",
      idle: "Idle connections in pool",
      waiting: "Connection requests waiting",
      size: "Maximum allowed connection pool size"
    }

    def initialize
      @active_record_metrics = []
    end

    def type
      "active_record"
    end

    def metrics
      return [] if @active_record_metrics.length == 0

      metrics = {}

      @active_record_metrics.map do |m|
        metric_key = (m["metric_labels"] || {}).merge("pid" => m["pid"])
        metric_key.merge!(m["custom_labels"]) if m["custom_labels"]

        ACTIVE_RECORD_GAUGES.map do |k, help|
          k = k.to_s
          if v = m[k]
            g = metrics[k] ||= PrometheusExporter::Metric::Gauge.new("active_record_connection_pool_#{k}", help)
            g.observe(v, metric_key)
          end
        end
      end

      metrics.values
    end

    def collect(obj)
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

      obj["created_at"] = now

      @active_record_metrics.delete_if do |current|
        (obj["pid"] == current["pid"] && obj["hostname"] == current["hostname"] &&
         obj["metric_labels"]["pool_name"] == current["metric_labels"]["pool_name"]) ||
          (current["created_at"] + MAX_ACTIVERECORD_METRIC_AGE < now)
      end

      @active_record_metrics << obj
    end
  end
end
