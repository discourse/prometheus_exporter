# frozen_string_literal: true

module PrometheusExporter::Metric
  class Counter < Base

    @counter_warmup_enabled = nil if !defined?(@counter_warmup_enabled)

    def self.counter_warmup=(enabled)
      @counter_warmup_enabled = enabled
    end

    def self.counter_warmup
      !!@counter_warmup_enabled
    end

    attr_reader :data

    def initialize(name, help)
      super
      reset!
    end

    def type
      "counter"
    end

    def reset!
      @data = {}
      @counter_warmup = {}
    end

    def metric_text
      @data.keys.map do |labels|
        value = warmup_counter_value(labels)
        "#{prefix(@name)}#{labels_text(labels)} #{value}"
      end.join("\n")
    end

    def to_h
      @data.dup
    end

    def remove(labels)
      @counter_warmup.delete(labels)
      @data.delete(labels)
    end

    def observe(increment = 1, labels = {})
      warmup_counter(labels)
      @data[labels] ||= 0
      @data[labels] += increment
    end

    def increment(labels = {}, value = 1)
      warmup_counter(labels)
      @data[labels] ||= 0
      @data[labels] += value
    end

    def decrement(labels = {}, value = 1)
      warmup_counter(labels)
      @data[labels] ||= 0
      @data[labels] -= value
    end

    def reset(labels = {}, value = 0)
      warmup_counter(labels)
      @data[labels] = value
    end

    private

    def warmup_counter(labels)
      if Counter.counter_warmup && !@data.has_key?(labels)
        @counter_warmup[labels] = 0
      end
    end

    def warmup_counter_value(labels)
      @counter_warmup.delete(labels) || @data[labels]
    end
  end
end
