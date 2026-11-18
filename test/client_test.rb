# frozen_string_literal: true

require_relative "test_helper"
require "prometheus_exporter/client"

class PrometheusExporterTest < Minitest::Test
  def test_find_the_correct_registered_metric
    client = PrometheusExporter::Client.new

    # register a metrics for testing
    counter_metric = client.register(:counter, "counter_metric", "helping")

    # when the given name doesn't match any existing metric, it returns nil
    result = client.find_registered_metric("not_registered")
    assert_nil(result)

    # when the given name matches an existing metric, it returns this metric
    result = client.find_registered_metric("counter_metric")
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given type doesn't, it returns nil
    result = client.find_registered_metric("counter_metric", type: :gauge)
    assert_nil(result)

    # when the given name and type match an existing metric, it returns the metric
    result = client.find_registered_metric("counter_metric", type: :counter)
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given help doesn't, it returns nil
    result = client.find_registered_metric("counter_metric", help: "not helping")
    assert_nil(result)

    # when the given name and help match an existing metric, it returns the metric
    result = client.find_registered_metric("counter_metric", help: "helping")
    assert_equal(counter_metric, result)

    # when the given name matches an existing metric, but the given help and type don't, it returns nil
    result = client.find_registered_metric("counter_metric", type: :gauge, help: "not helping")
    assert_nil(result)

    # when the given name, type, and help all match an existing metric, it returns the metric
    result = client.find_registered_metric("counter_metric", type: :counter, help: "helping")
    assert_equal(counter_metric, result)
  end

  def test_standard_values
    client = PrometheusExporter::Client.new
    counter_metric = client.register(:counter, "counter_metric", "helping")
    assert_equal(false, counter_metric.standard_values("value", "key").has_key?(:opts))

    expected_quantiles = { quantiles: [0.99, 9] }
    summary_metric = client.register(:summary, "summary_metric", "helping", expected_quantiles)
    assert_equal(expected_quantiles, summary_metric.standard_values("value", "key")[:opts])
  end

  def test_close_socket_on_error
    logs = StringIO.new
    logger = Logger.new(logs)
    logger.level = :error

    client =
      PrometheusExporter::Client.new(logger: logger, port: 321, process_queue_once_and_stop: true)
    client.send("put a message in the queue")

    assert_includes(
      logs.string,
      "Prometheus Exporter, failed to send message Connection refused - connect(2) for \"localhost\" port 321",
    )
  end

  def test_overriding_logger
    logs = StringIO.new
    logger = Logger.new(logs)
    logger.level = :warn

    client =
      PrometheusExporter::Client.new(
        logger: logger,
        max_queue_size: 1,
        process_queue_once_and_stop: true,
      )
    client.send("put a message in the queue")
    client.send("put a second message in the queue to trigger the logger")

    assert_includes(logs.string, "dropping message cause queue is full")
  end

  def test_invalid_naming
    client = PrometheusExporter::Client.new(custom_labels: {"label" => 1})

    refute_same(false, client.send_json({}))
    refute_same(false, client.send_json({name: "valid_name"}))
    refute_same(false, client.send_json({name: "__valid_name"}))
    refute_same(false, client.send_json({name: "__valid_name_1"}))
    refute_same(false, client.send_json({name: "__valid_name_1", custom_labels: {"valid_name" => "value"}}))
    refute_same(false, client.send_json({name: "valid_name", custom_labels: {"_valid_name" => "value"}}))

    assert_equal(false, client.send_json({name: "invalid-name"}))
    assert_equal(false, client.send_json({name: "valid_name", custom_labels: {"__invalid_name" => "value"}}))
    assert_equal(false, client.send_json({name: "valid_name", custom_labels: {"invalid-name" => "value"}}))

    client.custom_labels = {"__invalid_name" => "value"}
    assert_equal(false, client.send_json({}))

    client.custom_labels = {"invalid-name" => "value"}
    assert_equal(false, client.send_json({}))
  end
end
