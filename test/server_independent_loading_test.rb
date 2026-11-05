# frozen_string_literal: true

# This test verifies that the server can be loaded independently
# without requiring the main prometheus_exporter module first.
#
# DO NOT require test_helper here, as it pre-loads the main module.

require "minitest/autorun"

class ServerIndependentLoadingTest < Minitest::Test
  def test_server_has_constants_when_loaded_independently
    require_relative "../lib/prometheus_exporter/server"

    assert_equal 9394, PrometheusExporter::DEFAULT_PORT
    assert_equal "localhost", PrometheusExporter::DEFAULT_BIND_ADDRESS
    assert_equal 2, PrometheusExporter::DEFAULT_TIMEOUT
    assert_equal "ruby_", PrometheusExporter::DEFAULT_PREFIX
    assert_equal "Prometheus Exporter", PrometheusExporter::DEFAULT_REALM
  end
end
