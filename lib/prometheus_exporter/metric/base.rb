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

    attr_accessor :help, :name

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
      <<~TEXT
        # HELP #{prefix(name)} #{help}
        # TYPE #{prefix(name)} #{type}
        #{metric_text}
      TEXT
    end
  end
end
