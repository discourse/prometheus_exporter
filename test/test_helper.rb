# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "prometheus_exporter"

require "minitest/autorun"

require "redis"

module TestingMod
  class FakeConnection
    def call_pipelined(_, _)
    end
    def call(_, _)
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

  def call(command, _config)
    super
  end

  def call_pipelined(command, _config)
    super
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
