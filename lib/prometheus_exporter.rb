# frozen_string_literal: true

require_relative "prometheus_exporter/version"
require "json"
require "thread"

module PrometheusExporter
  # per: https://github.com/prometheus/prometheus/wiki/Default-port-allocations
  DEFAULT_PORT = 9394
  DEFAULT_BIND_ADDRESS = 'localhost'
  DEFAULT_PREFIX = 'ruby_'
  DEFAULT_LABEL = {}
  DEFAULT_TIMEOUT = 2
  DEFAULT_REALM = 'Prometheus Exporter'

  class OjCompat
    def self.parse(obj)
      Oj.compat_load(obj)
    end
    def self.dump(obj)
      Oj.dump(obj, mode: :compat)
    end
  end

  def self.hostname
    @hostname ||=
      begin
        require 'socket'
        Socket.gethostname
      rescue => e
        STDERR.puts "Unable to lookup hostname #{e}"
        "unknown-host"
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
