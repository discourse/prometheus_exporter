# frozen_string_literal: true

require_relative "../test_helper"
require "prometheus_exporter/instrumentation"

# Minimal GoodJob test double. Each scope returns a relation-like object that
# answers #size, #minimum(:scheduled_at) (ungrouped) and #group(:queue_name)
# (which in turn answers #count and #minimum), matching the subset of the
# GoodJob::Job / GoodJob::Process API the instrumentation relies on.
module GoodJob
  class FakeGrouped
    def initialize(by_queue, oldest_by_queue)
      @by_queue = by_queue
      @oldest_by_queue = oldest_by_queue
    end

    def count
      @by_queue
    end

    def minimum(_column)
      @oldest_by_queue
    end
  end

  class FakeRelation
    def initialize(total, by_queue = {}, oldest = nil, oldest_by_queue = {})
      @total = total
      @by_queue = by_queue
      @oldest = oldest
      @oldest_by_queue = oldest_by_queue
    end

    def size
      @total
    end

    def minimum(_column)
      @oldest
    end

    def group(_column)
      FakeGrouped.new(@by_queue, @oldest_by_queue)
    end
  end

  class Job
    class << self
      attr_accessor :relations

      %i[scheduled retried queued running finished succeeded discarded].each do |scope|
        define_method(scope) { relations.fetch(scope) }
      end
    end
  end

  class Process
    class Active
      def count
        2
      end
    end

    def self.active
      Active.new
    end
  end
end

class PrometheusInstrumentationGoodJobTest < Minitest::Test
  def setup
    super
    GoodJob::Job.relations = {
      scheduled: relation(3),
      retried: relation(4),
      queued: relation(5, { "default" => 4, "mailers" => 1 }, minutes_ago(1), { "default" => minutes_ago(1), "mailers" => seconds_ago(5) }),
      running: relation(2),
      finished: relation(100),
      succeeded: relation(2000),
      discarded: relation(9),
    }
  end

  def collector
    @collector ||= PrometheusExporter::Instrumentation::GoodJob.new
  end

  def test_collect_is_backwards_compatible_and_adds_new_keys
    data = collector.collect

    assert_equal "good_job", data[:type]
    assert_equal 3, data[:scheduled]
    assert_equal 5, data[:queued]
    assert_equal 9, data[:discarded]
    # New, purely-additive gauges:
    assert_operator data[:oldest_queued_age_seconds], :>=, 59
    assert_equal 2, data[:processes]
    refute(data.key?(:custom_labels), "default mode must not emit a queue label")
  end

  def test_collect_per_queue_labels_each_queue
    metrics = collector.collect_per_queue

    labelled = metrics.select { |metric| metric.key?(:custom_labels) }
    default = labelled.find { |metric| metric[:custom_labels][:queue] == "default" }
    mailers = labelled.find { |metric| metric[:custom_labels][:queue] == "mailers" }

    assert_equal 4, default[:queued]
    assert_equal 1, mailers[:queued]
    # zero-filled where a queue has no jobs in a given state
    assert_equal 0, default[:scheduled]
    assert_operator default[:oldest_queued_age_seconds], :>=, 59

    # a single unlabelled object carries the cluster-wide process count
    global = metrics.find { |metric| !metric.key?(:custom_labels) }
    assert_equal 2, global[:processes]
  end

  private

  def relation(total, by_queue = {}, oldest = nil, oldest_by_queue = {})
    GoodJob::FakeRelation.new(total, by_queue, oldest, oldest_by_queue)
  end

  def minutes_ago(minutes)
    Time.now - (minutes * 60)
  end

  def seconds_ago(seconds)
    Time.now - seconds
  end
end
