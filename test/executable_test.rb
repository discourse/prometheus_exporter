# frozen_string_literal: true

require_relative "test_helper"
# The extensionless executable cannot be loaded with require_relative.
# rubocop:disable Discourse/Plugins/UseRequireRelative
load File.expand_path("../exe/prometheus_exporter", __dir__)
# rubocop:enable Discourse/Plugins/UseRequireRelative

class PrometheusExporterExecutableTest < Minitest::Test
  def test_max_record_size_option_is_forwarded_to_runner
    captured_options = nil
    stop = Class.new(StandardError)
    runner_factory =
      lambda do |options|
        captured_options = options
        raise stop
      end

    assert_raises(stop) do
      PrometheusExporter::Server::Runner.stub(:new, runner_factory) do
        run_prometheus_exporter(%w[--max-record-size 123456])
      end
    end

    assert_equal(123_456, captured_options[:max_record_size])
  end

  def test_help_documents_max_record_size_option
    stdout, = capture_io { assert_raises(SystemExit) { run_prometheus_exporter(["--help"]) } }

    assert_includes(stdout, "--max-record-size INTEGER")
  end
end
