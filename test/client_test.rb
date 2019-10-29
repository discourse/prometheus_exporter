# frozen_string_literal: true

require "test_helper"

class PrometheusExporterTest < Minitest::Test
  def test_find_the_correct_registered_metric
    client = PrometheusExporter::Client.new

    # register a metrics for testing
    counter_metric = client.register(:counter, 'counter_metric', 'helping')

    # when the given name doesn't match any existing metric, it returns nil
    result = client.find_registered_metric('not_registered')
    assert_nil(result)

    # when the given name matches an existing metric, it returns this metric
    result = client.find_registered_metric('counter_metric')
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given type doesn't, it returns nil
    result = client.find_registered_metric('counter_metric', type: :gauge)
    assert_nil(result)

    # when the given name and type match an existing metric, it returns the metric
    result = client.find_registered_metric('counter_metric', type: :counter)
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given help doesn't, it returns nil
    result = client.find_registered_metric('counter_metric', help: 'not helping')
    assert_nil(result)

    # when the given name and help match an existing metric, it returns the metric
    result = client.find_registered_metric('counter_metric', help: 'helping')
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given help and type don't, it returns nil
    result = client.find_registered_metric('counter_metric', type: :gauge, help: 'not helping')
    assert_nil(result)

    # when the given name, type, and help all match an existing metric, it returns the metric
    result = client.find_registered_metric('counter_metric', type: :counter, help: 'helping')
    assert_equal(counter_metric, result)
  end

  def test_standard_values
    client = PrometheusExporter::Client.new
    counter_metric = client.register(:counter, 'counter_metric', 'helping')
    assert_equal(false, counter_metric.standard_values('value', 'key').has_key?(:opts))

    expected_quantiles = { quantiles: [0.99, 9] }
    summary_metric = client.register(:summary, 'summary_metric', 'helping', expected_quantiles)
    assert_equal(expected_quantiles, summary_metric.standard_values('value', 'key')[:opts])
  end
end
