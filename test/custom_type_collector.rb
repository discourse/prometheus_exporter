# frozen_string_literal: true

class CustomTypeCollector < PrometheusExporter::Server::TypeCollector
  def type
    "custom1"
  end

  def observe(obj)
    p obj
  end

  def metrics
    []
  end
end
