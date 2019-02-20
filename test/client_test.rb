require "test_helper"
require 'prometheus_exporter/client'

# Mock queue reduces its length as it is checked
class MockQueue
  def length
    @queue_length = (@queue_length || 3) - 1
    @queue_length < 0 ? 0 : @queue_length
  end
end

describe PrometheusExporter::Client do
  
  before do
    @client = PrometheusExporter::Client.default
  end

  describe "flush" do
    it "sends all queued entries within the timeout" do
      @client.instance_variable_set(:@queue, MockQueue.new())
      assert @client.flush(0.1)
    end
    it "fails to send queued entries before the timeot" do
      @client.instance_variable_set(:@queue, [99])
      refute @client.flush(0.1)
    end
  end
  
end
  
