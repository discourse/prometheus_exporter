module PrometheusExporter::Instrumentation
  class ActiveRecord
    def self.start(client: nil)
      require "active_support/subscriber"
      require "prometheus_exporter/utils/sql_sanitizer"

      ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        active_record = new(event, client: client)
        begin
          active_record.call
        rescue => e
          STDERR.puts("Prometheus Exporter Failed To Collect Active Record Stats #{e}")
        end
      end
    end

    def initialize(event, client: nil)
      @client = client || PrometheusExporter::Client.default
      @active_record_event = event
    end

    def call
      return if name == "SCHEMA".freeze || name == "CACHE".freeze

      @client.send_json(
        type: "active_record",
        duration: duration,
        action: name,
        query: clean_query
      )
    end

    private

    def name
      @active_record_event.payload[:name]
    end

    def duration
      @active_record_event.duration / 1000
    end

    def clean_query
      raw_sql = @active_record_event.payload[:sql]
      sql = PrometheusExporter::Utils::SqlSanitizer.new(raw_sql)
      sql.to_s
    end
  end
end
