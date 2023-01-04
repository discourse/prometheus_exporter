# frozen_string_literal: true

require "prometheus_exporter/server/metrics_container"

module PrometheusExporter::Server
  class TypeCollector
    def type
      raise "must implement type"
    end

    def collect(obj)
      raise "must implement collect"
    end

    def metrics
      raise "must implement metrics"
    end
  end
end
