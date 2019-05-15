# frozen_string_literal: true

module PrometheusExporter::Server

  # minimal interface to implement a customer collector
  class CollectorBase

    # called each time a string is delivered from the web
    def process(str)
    end

    # a string denoting the metrics
    def prometheus_metrics_text(str)
    end
  end
end
