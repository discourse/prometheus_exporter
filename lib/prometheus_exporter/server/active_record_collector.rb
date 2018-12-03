module PrometheusExporter::Server
  class ActiveRecordCollector < TypeCollector
    def type
      "active_record"
    end

    def collect(obj)
      default_labels = { query: obj["query"], action: obj["action"] }
      custom_labels = obj["custom_labels"]
      labels = custom_labels.nil? ? default_labels : default_labels.merge(custom_labels)

      ensure_active_record_metrics
      @active_record_query_duration_seconds.observe(obj["duration"], labels)
      @active_record_query_duration_seconds_summary.observe(obj["duration"])
      @active_record_queries_total.observe(1, labels)
    end

    def metrics
      if @active_record_queries_total
        [
          @active_record_query_duration_seconds,
          @active_record_query_duration_seconds_summary,
          @active_record_queries_total
        ]
      else
        []
      end
    end

    protected

    def ensure_active_record_metrics
      if !@active_record_queries_total

        @active_record_query_duration_seconds = PrometheusExporter::Metric::Counter.new(
          "active_record_query_duration_seconds", "Total time spent in queries."
        )

        @active_record_query_duration_seconds_summary = PrometheusExporter::Metric::Summary.new(
          "active_record_query_duration_seconds_summary", "Summary of the time it takes queries to execute.")

        @active_record_queries_total = PrometheusExporter::Metric::Counter.new(
          "active_record_queries_total", "Total number of queries executed."
        )
      end
    end
  end
end
