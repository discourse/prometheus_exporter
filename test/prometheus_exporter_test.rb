# frozen_string_literal: true

require_relative "test_helper"

class PrometheusExporterTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::PrometheusExporter::VERSION
  end

  def test_it_can_get_hostname
    assert_equal `hostname`.strip, ::PrometheusExporter.hostname
  end
end
