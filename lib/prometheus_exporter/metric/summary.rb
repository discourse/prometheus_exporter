# frozen_string_literal: true

module PrometheusExporter::Metric
  class Summary < Base

    QUANTILES = [0.99, 0.9, 0.5, 0.1, 0.01]
    ROTATE_AGE = 120

    attr_reader :estimators, :count, :total

    def initialize(name, help)
      super
      @buffers = [{}, {}]
      @last_rotated = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @current_buffer = 0
      @counts = {}
      @sums = {}
    end

    def type
      "summary"
    end

    def calculate_quantiles(raw_data)
      sorted = raw_data.sort
      length = sorted.length
      result = {}

      if length > 0
        QUANTILES.each do |quantile|
          result[quantile] = sorted[(length * quantile).ceil - 1]
        end
      end

      result
    end

    def calculate_all_quantiles
      buffer = @buffers[@current_buffer]

      result = {}
      buffer.each do |labels, raw_data|
        result[labels] = calculate_quantiles(raw_data)
      end

      result

    end

    def metric_text
      text = String.new
      first = true
      calculate_all_quantiles.each do |labels, quantiles|
        text << "\n" unless first
        first = false
        quantiles.each do |quantile, value|
          with_quantile = labels.merge(quantile: quantile)
          text << "#{prefix(@name)}#{labels_text(with_quantile)} #{value.to_f}\n"
        end
        text << "#{prefix(@name)}_sum#{labels_text(labels)} #{@sums[labels]}\n"
        text << "#{prefix(@name)}_count#{labels_text(labels)} #{@counts[labels]}"
      end
      text
    end

    # makes sure we have storage
    def ensure_summary(labels)
      @buffers[0][labels] ||=  []
      @buffers[1][labels] ||=  []
      @sums[labels] ||= 0.0
      @counts[labels] ||= 0
      nil
    end

    def rotate_if_needed
      if (now = Process.clock_gettime(Process::CLOCK_MONOTONIC)) > (@last_rotated + ROTATE_AGE)
        @last_rotated = now
        @buffers[@current_buffer].each do |labels, raw|
          raw.clear
        end
        @current_buffer = @current_buffer == 0 ? 1 : 0
      end
      nil
    end

    def observe(value, labels = {})
      ensure_summary(labels)
      rotate_if_needed

      value = value.to_f
      @buffers[0][labels] << value
      @buffers[1][labels] << value
      @sums[labels] += value
      @counts[labels] += 1
    end

  end
end
