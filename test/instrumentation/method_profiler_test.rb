# frozen_string_literal: true

require_relative '../test_helper'
require 'prometheus_exporter/instrumentation'

class PrometheusInstrumentationMethodProfilerTest < Minitest::Test
  class SomeClassPatchedUsingAliasMethod
    def some_method
      "Hello, world"
    end
  end

  class SomeClassPatchedUsingPrepend
    def some_method
      "Hello, world"
    end
  end

  def setup
    PrometheusExporter::Instrumentation::MethodProfiler.patch SomeClassPatchedUsingAliasMethod, [:some_method], :test, instrument: :alias_method
    PrometheusExporter::Instrumentation::MethodProfiler.patch SomeClassPatchedUsingPrepend, [:some_method], :test, instrument: :prepend
  end

  def test_alias_method_source_location
    file, line = SomeClassPatchedUsingAliasMethod.instance_method(:some_method).source_location
    source = File.read(file).lines[line - 1].strip
    assert_equal 'def #{method_name}(*args, &blk)', source
  end

  def test_prepend_source_location
    file, line = SomeClassPatchedUsingPrepend.instance_method(:some_method).source_location
    source = File.read(file).lines[line - 1].strip
    assert_equal 'def #{method_name}(*args, &blk)', source
  end
end
