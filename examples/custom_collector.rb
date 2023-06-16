# frozen_string_literal: true

class MyCustomCollector < PrometheusExporter::Server::BaseCollector
  def initialize
    @gauge1 = PrometheusExporter::Metric::Gauge.new("thing1", "I am thing 1")
    @gauge2 = PrometheusExporter::Metric::Gauge.new("thing2", "I am thing 2")
    @mutex = Mutex.new
  end

  def process(obj)
    @mutex.synchronize do
      if thing1 = obj["thing1"]
        @gauge1.observe(thing1)
      end

      if thing2 = obj["thing2"]
        @gauge2.observe(thing2)
      end
    end
  end

  def prometheus_metrics_text
    @mutex.synchronize do
      "#{@gauge1.to_prometheus_text}\n#{@gauge2.to_prometheus_text}"
    end
  end
end
