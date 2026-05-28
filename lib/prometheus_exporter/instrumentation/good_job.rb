# frozen_string_literal: true

# collects stats from GoodJob
module PrometheusExporter::Instrumentation
  class GoodJob < PeriodicStats
    STATE_SCOPES = %i[scheduled retried queued running finished succeeded discarded].freeze

    # @param per_queue [Boolean] when true, the job-state gauges and the
    #   oldest-queued-age gauge are additionally broken down by queue via a
    #   +queue+ label. Defaults to false, which preserves the original
    #   cluster-wide (unlabelled) output exactly.
    def self.start(client: nil, frequency: 30, per_queue: false)
      good_job_collector = new
      client ||= PrometheusExporter::Client.default

      if per_queue
        worker_loop { good_job_collector.collect_per_queue.each { |metric| client.send_json(metric) } }
      else
        worker_loop { client.send_json(good_job_collector.collect) }
      end

      super
    end

    # Cluster-wide totals (no queue label). Backwards compatible: the original
    # keys are unchanged; +oldest_queued_age_seconds+ and +processes+ are added.
    def collect
      {
        type: "good_job",
        scheduled: ::GoodJob::Job.scheduled.size,
        retried: ::GoodJob::Job.retried.size,
        queued: ::GoodJob::Job.queued.size,
        running: ::GoodJob::Job.running.size,
        finished: ::GoodJob::Job.finished.size,
        succeeded: ::GoodJob::Job.succeeded.size,
        discarded: ::GoodJob::Job.discarded.size,
        oldest_queued_age_seconds: oldest_queued_age_seconds,
        processes: process_count,
      }
    end

    # One metric object per queue (job-state counts + oldest-queued-age, each
    # carrying a +queue+ custom label), plus a single unlabelled object for the
    # cluster-wide process count. The job-state totals are intentionally not
    # emitted unlabelled here so a metric never mixes labelled and unlabelled
    # series (which would make a naive sum() double-count).
    def collect_per_queue
      states = STATE_SCOPES.to_h { |scope| [scope, ::GoodJob::Job.public_send(scope).group(:queue_name).count] }
      oldest = ::GoodJob::Job.queued.group(:queue_name).minimum(:scheduled_at)
      now = Time.now

      queues = (states.values.flat_map(&:keys) + oldest.keys).uniq
      metrics =
        queues.map do |queue|
          metric = { type: "good_job", custom_labels: { queue: queue } }
          STATE_SCOPES.each { |scope| metric[scope] = states.fetch(scope)[queue] || 0 }
          oldest_at = oldest[queue]
          metric[:oldest_queued_age_seconds] = oldest_at ? age_in_seconds(oldest_at, now) : 0
          metric
        end

      metrics << { type: "good_job", processes: process_count }
      metrics
    end

    private

    def oldest_queued_age_seconds(now = Time.now)
      oldest_at = ::GoodJob::Job.queued.minimum(:scheduled_at)
      oldest_at ? age_in_seconds(oldest_at, now) : 0
    end

    def age_in_seconds(timestamp, now)
      [(now - timestamp).to_i, 0].max
    end

    def process_count
      return 0 unless defined?(::GoodJob::Process)

      ::GoodJob::Process.active.count
    end
  end
end
