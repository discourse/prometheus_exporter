# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/instrumentation"
require "active_record"

class PrometheusInstrumentationActiveRecordTest < Minitest::Test
  def setup
    super

    # With this trick this variable with be accessible with ::ObjectSpace
    @pool =
      if active_record_version >= Gem::Version.create("6.1.0.rc1")
        active_record61_pool
      elsif active_record_version >= Gem::Version.create("6.0.0")
        active_record60_pool
      else
        raise "unsupported active_record version"
      end
  end

  def metric_labels
    { foo: :bar }
  end

  def config_labels
    %i[database username]
  end

  def collector
    @collector ||=
      PrometheusExporter::Instrumentation::ActiveRecord.new(metric_labels, config_labels)
  end

  %i[size connections busy dead idle waiting checkout_timeout type metric_labels].each do |key|
    define_method("test_collecting_metrics_contain_#{key}_key") do
      assert_includes collector.collect.first, key
    end
  end

  def test_metrics_labels
    assert_includes collector.collect.first[:metric_labels], :foo
  end

  def test_type
    assert_equal collector.collect.first[:type], "active_record"
  end

  private

  def active_record_version
    Gem.loaded_specs["activerecord"].version
  end

  def active_record60_pool
    ::ActiveRecord::ConnectionAdapters::ConnectionPool.new(OpenStruct.new(config: {}))
  end

  def active_record61_pool
    ::ActiveRecord::ConnectionAdapters::ConnectionPool.new(
      OpenStruct.new(db_config: OpenStruct.new(checkout_timeout: 0, idle_timeout: 0, pool: 5)),
    )
  end
end
