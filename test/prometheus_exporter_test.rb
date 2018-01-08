require "test_helper"

class PrometheusExporterTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::PrometheusExporter::VERSION
  end
end
