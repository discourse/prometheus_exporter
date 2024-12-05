# frozen_string_literal: true

module PrometheusExporter::Metric
  class Gauge < Base
    attr_reader :data

    def initialize(name, help)
      if name.end_with?("_total")
        raise ArgumentError, "The metric name of gauge must not have _total suffix. Given: #{name}"
      end

      super
      reset!
    end

    def type
      "gauge"
    end

    def metric_text
      @data.map { |labels, value| "#{prefix(@name)}#{labels_text(labels)} #{value}" }.join("\n")
    end

    def reset!
      @data = {}
    end

    def to_h
      @data.dup
    end

    def remove(labels)
      @data.delete(labels)
    end

    def observe(value, labels = {})
      if value.nil?
        data.delete(labels)
      else
        raise ArgumentError, "value must be a number" if !(Numeric === value)
        @data[labels] = value
      end
    end

    alias_method :set, :observe

    def increment(labels = {}, value = 1)
      @data[labels] ||= 0
      @data[labels] += value
    end

    def decrement(labels = {}, value = 1)
      @data[labels] ||= 0
      @data[labels] -= value
    end
  end
end
