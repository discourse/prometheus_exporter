module PrometheusExporter
  module Utils
    class Rails
      def database_engine
        @database_engine ||= begin
          if defined?(ActiveRecord::Base)
            case raw_database_adapter.to_s
            when "postgres"   then :postgres
            when "postgresql" then :postgres
            when "postgis"    then :postgres
            when "sqlite3"    then :sqlite
            when "sqlite"     then :sqlite
            when "mysql"      then :mysql
            when "mysql2"     then :mysql
            else :postgres
            end
          else
            :postgres
          end
        end
      end

      def raw_database_adapter
        adapter = ActiveRecord::Base.connection_config[:adapter].to_s rescue nil

        if adapter.nil?
          adapter = ActiveRecord::Base.configurations[env]["adapter"]
        end

        return adapter
      rescue
        nil
      end
    end
  end
end