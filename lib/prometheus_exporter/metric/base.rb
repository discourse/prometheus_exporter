# frozen_string_literal: true

module PrometheusExporter::Metric
  class Base
    # prefix applied to all metrics
    def self.default_prefix=(name)
      @default_prefix = name
    end

    def self.default_prefix
      @default_prefix.to_s
    end

    attr_accessor :help, :name, :data

    def initialize(name, help)
      @name = name
      @help = help
    end

    def type
      raise "Not implemented"
    end

    def metric_text
      raise "Not implemented"
    end

    def from_json(json)
      json = JSON.parse(json) if String === json
      @name = json["name"]
      @help = json["help"]
      @data = json["data"]
      if Hash === json["data"]
        @data = {}
        json["data"].each do |k, v|
          k = JSON.parse(k)
          k = Hash[k.map { |k1, v1| [k1.to_sym, v1] }]
          @data[k] = v
        end
      end
    end

    def prefix(name)
      Base.default_prefix + name
    end

    def labels_text(labels)
      if labels && labels.length > 0
        s = labels.map do |key, value|
          "#{key}=\"#{value}\""
        end.join(",")
        "{#{s}}"
      end
    end

    def to_prometheus_text
      <<-TEXT
# HELP #{prefix(name)} #{help}
# TYPE #{prefix(name)} #{type}
#{metric_text}
      TEXT
    end
  end
end
