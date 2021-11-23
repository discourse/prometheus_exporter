# frozen_string_literal: true

require_relative '../test_helper'
require 'prometheus_exporter/instrumentation'

class PrometheusInstrumentationMethodProfilerTest < Minitest::Test
  class SomeClass
    def some_method
      "Hello, world"
    end
  end

  def setup
    PrometheusExporter::Instrumentation::MethodProfiler.patch SomeClass, [:some_method], :test
  end

  def test_source_location
    file, line = SomeClass.instance_method(:some_method).source_location
    source = File.read(file).lines[line - 1].strip

    assert_equal 'def #{method_name}(*args, &blk)', source
  end
end
