# frozen_string_literal: true

module PrometheusExporter::Server
  class MetricsContainer
    METRIC_MAX_AGE = 60
    METRIC_EXPIRE_ATTR = "_expire_at"

    attr_reader :data, :ttl
    attr_accessor :filter

    def initialize(ttl: METRIC_MAX_AGE, expire_attr: METRIC_EXPIRE_ATTR, filter: nil)
      @data          = []
      @ttl           = ttl
      @expire_attr   = expire_attr
      @filter        = filter
    end

    def <<(obj)
      now = get_time
      obj[@expire_attr] = now + @ttl

      expire(time: now, new_metric: obj)

      @data << obj
      @data
    end

    def [](key)
      @data.tap { expire }[key]
    end

    def size(&blk)
      wrap_expire(:size, &blk)
    end
    alias_method :length, :size

    def map(&blk)
      wrap_expire(:map, &blk)
    end

    def each(&blk)
      wrap_expire(:each, &blk)
    end

    def expire(time: nil, new_metric: nil)
      time ||= get_time

      @data.delete_if do |metric|
        expired = metric[@expire_attr] < time
        expired ||= filter.call(new_metric, metric) if @filter && new_metric
        expired
      end
    end

    private

    def get_time
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    def wrap_expire(method_name, &blk)
      expire
      @data.public_send(method_name, &blk)
    end
  end
end
