# frozen_string_literal: true

require_relative "prometheus_exporter/version"
require "json"
require "thread"

module PrometheusExporter
  # per: https://github.com/prometheus/prometheus/wiki/Default-port-allocations
  DEFAULT_PORT = 9394
  DEFAULT_PREFIX = 'ruby_'
  DEFAULT_TIMEOUT = 2

  class OjCompat
    def self.parse(obj)
      Oj.compat_load(obj)
    end
    def self.generate(obj)
      Oj.dump(obj, mode: :compat)
    end
  end

  def self.detect_json_serializer(preferred)
    if preferred.nil?
      preferred = :oj if has_oj?
    end

    preferred == :oj ? OjCompat : JSON
  end

  @@has_oj = nil
  def self.has_oj?
    (
      @@has_oj ||=
       begin
         require 'oj'
         :true
       rescue LoadError
         :false
       end
    ) == :true
  end

end
