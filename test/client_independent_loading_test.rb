# frozen_string_literal: true

# This test verifies that the client can be loaded independently
# without requiring the main prometheus_exporter module first.
#
# DO NOT require test_helper here, as it pre-loads the main module.

require "minitest/autorun"

class ClientIndependentLoadingTest < Minitest::Test
  def test_client_has_constants_when_loaded_independently
    require_relative "../lib/prometheus_exporter/client"

    assert_equal 9394, PrometheusExporter::DEFAULT_PORT
    assert_equal "localhost", PrometheusExporter::DEFAULT_BIND_ADDRESS
    assert_equal 2, PrometheusExporter::DEFAULT_TIMEOUT
  end
end
