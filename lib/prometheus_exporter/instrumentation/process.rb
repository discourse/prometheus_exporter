# frozen_string_literal: true

# collects stats from currently running process
module PrometheusExporter::Instrumentation
  class Process < PeriodicStats

    def self.start(client: nil, type: "ruby", frequency: 30, labels: nil)

      metric_labels =
        if labels && type
          labels.merge(type: type)
        elsif labels
          labels
        else
          { type: type }
        end

      process_collector = new(metric_labels)
      client ||= PrometheusExporter::Client.default

      worker_loop do
        metric = process_collector.collect
        client.send_json metric
      end

      super
    end

    def initialize(metric_labels)
      @metric_labels = metric_labels
    end

    def collect
      metric = {}
      metric[:type] = "process"
      metric[:metric_labels] = @metric_labels
      metric[:hostname] = ::PrometheusExporter.hostname
      collect_gc_stats(metric)
      collect_v8_stats(metric)
      collect_process_stats(metric)
      metric
    end

    def pid
      @pid = ::Process.pid
    end

    def rss
      @pagesize ||= `getconf PAGESIZE`.to_i rescue 4096
      File.read("/proc/#{pid}/statm").split(' ')[1].to_i * @pagesize rescue 0
    end

    def collect_process_stats(metric)
      metric[:pid] = pid
      metric[:rss] = rss

    end

    def collect_gc_stats(metric)
      stat = GC.stat
      metric[:heap_live_slots] = stat[:heap_live_slots]
      metric[:heap_free_slots] = stat[:heap_free_slots]
      metric[:major_gc_ops_total] = stat[:major_gc_count]
      metric[:minor_gc_ops_total] = stat[:minor_gc_count]
      metric[:allocated_objects_total] = stat[:total_allocated_objects]
    end

    def collect_v8_stats(metric)
      return if !defined? MiniRacer

      metric[:v8_heap_count] = metric[:v8_heap_size] = 0
      metric[:v8_heap_size] = metric[:v8_physical_size] = 0
      metric[:v8_used_heap_size] = 0

      ObjectSpace.each_object(MiniRacer::Context) do |context|
        stats = context.heap_stats
        if stats
          metric[:v8_heap_count] += 1
          metric[:v8_heap_size] += stats[:total_heap_size].to_i
          metric[:v8_used_heap_size] += stats[:used_heap_size].to_i
          metric[:v8_physical_size] += stats[:total_physical_size].to_i
        end
      end
    end
  end
end
