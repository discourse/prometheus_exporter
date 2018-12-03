$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
require "prometheus_exporter"

require "minitest/autorun"

class TestHelper
  def self.wait_for(time, &blk)
    (time / 0.001).to_i.times do
      return true if blk.call
      sleep 0.001
    end
    false
  end
end
