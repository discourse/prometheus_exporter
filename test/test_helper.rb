# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "prometheus_exporter"

require "minitest/autorun"
require "ostruct"
require "redis"

module TestingMod
  class FakeConnection
    def call_pipelined(...)
    end

    def call(...)
    end

    def connected?
      true
    end

    def revalidate
    end

    def read_timeout=(v)
    end

    def write_timeout=(v)
    end
  end

  def connect(_config)
    FakeConnection.new
  end
end

module RedisValidationMiddleware
  def self.reset!
    @@call_calls = 0
    @@call_pipelined_calls = 0
  end

  def self.call_calls
    @@call_calls || 0
  end

  def self.call_pipelined_calls
    @@call_pipelined_calls || 0
  end

  def call(command, _config)
    @@call_calls ||= 0
    @@call_calls += 1
    super
  end

  def call_pipelined(command, _config)
    @@call_pipelined_calls ||= 0
    @@call_pipelined_calls += 1
    super
  end
end

RedisClient::Middlewares.prepend(TestingMod)
RedisClient.register(RedisValidationMiddleware)

class TestHelper
  def self.wait_for(time, &blk)
    (time / 0.001).to_i.times do
      return true if blk.call
      sleep 0.001
    end
    false
  end
end

module ClockHelper
  def stub_monotonic_clock(at = 0.0, advance: nil, &blk)
    Process.stub(:clock_gettime, at + advance.to_f, Process::CLOCK_MONOTONIC, &blk)
  end
end

module CollectorHelper
  def setup
    PrometheusExporter::Metric::Base.default_prefix = ""
  end

  def max_metric_age
    @_max_age ||= get_max_metric_age
  end

  def collector_metric_lines
    collector.metrics.map(&:metric_text).join("\n").split("\n")
  end

  def assert_collector_metric_lines(expected)
    assert_equal(expected, collector_metric_lines)
  end

  private

  def get_max_metric_age
    klass = @collector.class
    unless klass.const_defined?(:MAX_METRIC_AGE)
      raise "Collector class #{@collector.class.name} must set MAX_METRIC_AGE constant!"
    end
    klass.const_get(:MAX_METRIC_AGE)
  end
end

# Allow stubbing process monotonic clock from any class in the suite
Minitest::Test.send(:include, ClockHelper)
