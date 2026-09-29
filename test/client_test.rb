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

  def test_send_json_supports_existing_send_overrides
    received = []
    client = PrometheusExporter::Client.new
    client.define_singleton_method(:send) { |json| received << JSON.parse(json) }

    client.send_json(type: "counter", value: 1)

    assert_equal([{ "type" => "counter", "value" => 1 }], received)
  end

  def test_send_json_queues_keyword_metrics_by_default
    socket = StringIO.new
    caller_thread = Thread.current
    write = socket.method(:write)
    client = PrometheusExporter::Client.new
    payload = JSON.generate(type: "counter", value: 1)

    socket.stub(
      :write,
      ->(data) do
        refute_equal(caller_thread, Thread.current)
        write.call(data)
      end,
    ) do
      TCPSocket.stub(:new, socket) do
        client.send_json(type: "counter", value: 1)
        assert(TestHelper.wait_for(2) { socket.string.include?("#{payload}\r\n") })
      end
    end

    assert_includes(socket.string, "#{payload.bytesize.to_s(16).upcase}\r\n#{payload}\r\n")
  ensure
    client&.stop
  end

  def test_send_json_with_sync_writes_on_the_calling_thread_with_custom_labels
    socket = StringIO.new
    caller_thread = Thread.current
    write = socket.method(:write)
    client = PrometheusExporter::Client.new(custom_labels: { region: "west", app: "default" })
    metric = { type: "counter", custom_labels: { app: "api" } }

    socket.stub(
      :write,
      ->(data) do
        assert_equal(caller_thread, Thread.current)
        write.call(data)
      end,
    ) { TCPSocket.stub(:new, socket) { client.send_json(metric, sync: true) } }

    payload = JSON.generate(type: "counter", custom_labels: { region: "west", app: "api" })
    assert_includes(socket.string, "#{payload.bytesize.to_s(16).upcase}\r\n#{payload}\r\n")
    assert_equal({ app: "api" }, metric[:custom_labels])
  ensure
    client&.stop
  end

  def test_send_with_sync_propagates_connection_errors
    client = PrometheusExporter::Client.new

    TCPSocket.stub(:new, ->(*) { raise Errno::ECONNREFUSED }) do
      assert_raises(Errno::ECONNREFUSED) { client.send("metric", sync: true) }
    end
  ensure
    client&.stop
  end

  def test_sync_send_does_not_interleave_with_a_background_write
    socket = StringIO.new
    write = socket.method(:write)
    writing = Queue.new
    resume = Queue.new
    client = PrometheusExporter::Client.new
    synchronous = nil

    socket.stub(
      :write,
      ->(data) do
        if data == "async"
          writing << true
          resume.pop
        end
        write.call(data)
      end,
    ) do
      TCPSocket.stub(:new, socket) do
        client.send("async")
        assert(TestHelper.wait_for(2) { !writing.empty? })
        synchronous = Thread.new { client.send("sync", sync: true) }
        assert(TestHelper.wait_for(2) { synchronous.status == "sleep" })
        refute_includes(socket.string, "sync\r\n")
        resume << true
        assert(synchronous.join(2))
      end
    end

    assert_includes(socket.string, "5\r\nasync\r\n4\r\nsync\r\n")
  ensure
    resume << true
    synchronous&.kill
    synchronous&.join
    client&.stop
  end

  def test_sync_send_does_not_wait_for_the_async_queue_to_empty
    socket = StringIO.new
    write = socket.method(:write)
    client = PrometheusExporter::Client.new
    writing = Queue.new
    replenish = true
    synchronous = nil

    socket.stub(
      :write,
      ->(data) do
        if data == "async"
          writing << true if writing.empty?
          client.send("async") if replenish
          Thread.pass
        end
        write.call(data)
      end,
    ) do
      TCPSocket.stub(:new, socket) do
        client.send("async")
        assert(TestHelper.wait_for(2) { !writing.empty? })

        synchronous = Thread.new { client.send("sync", sync: true) }

        assert(synchronous.join(2), "synchronous send waited for the async queue to empty")
      end
    end
  ensure
    replenish = false
    synchronous&.kill
    synchronous&.join
    client&.stop
  end

  def test_local_client_supports_synchronous_sending
    received = []
    collector = Object.new
    client = PrometheusExporter::LocalClient.new(collector: collector)
    collector.define_singleton_method(:process) { |json| received << JSON.parse(json) }

    client.send_json(type: "counter", value: 1, sync: true)

    assert_equal([{ "type" => "counter", "value" => 1 }], received)
  end
end
