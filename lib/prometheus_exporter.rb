require_relative "prometheus_exporter/version"
require "json"
require "thread"

module PrometheusExporter
  # per: https://github.com/prometheus/prometheus/wiki/Default-port-allocations
  DEFAULT_PORT = 9394
end
