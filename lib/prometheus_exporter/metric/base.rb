# frozen_string_literal: true

module PrometheusExporter::Metric
  class Base

    @default_prefix = nil if !defined?(@default_prefix)
    @default_labels = nil if !defined?(@default_labels)
    @default_aggregation = nil if !defined?(@default_aggregation)

    # prefix applied to all metrics
    def self.default_prefix=(name)
      @default_prefix = name
    end

    def self.default_prefix
      @default_prefix.to_s
    end

    def self.default_labels=(labels)
      @default_labels = labels
    end

    def self.default_labels
      @default_labels || {}
    end

    def self.default_aggregation=(aggregation)
      @default_aggregation = aggregation
    end

    def self.default_aggregation
      @default_aggregation ||= Summary
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

    def reset!
      raise "Not implemented"
    end

    def to_h
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
      labels = Base.default_labels.merge(labels || {})
      if labels && labels.length > 0
        s = labels.map do |key, value|
          value = value.to_s
          value = escape_value(value) if needs_escape?(value)
          "#{key}=\"#{value}\""
        end.join(",")
        "{#{s}}"
      end
    end

    def to_prometheus_text
      <<~TEXT
        # HELP #{prefix(name)} #{help}
        # TYPE #{prefix(name)} #{type}
        #{metric_text}
      TEXT
    end

    private

    def escape_value(str)
      str.gsub(/[\n"\\]/m) do |m|
        if m == "\n"
          "\\n"
        else
          "\\#{m}"
        end
      end
    end

    def needs_escape?(str)
      str.match?(/[\n"\\]/m)
    end

  end
end
