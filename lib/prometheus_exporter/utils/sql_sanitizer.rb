require 'prometheus_exporter/utils/rails'
require 'active_support/core_ext/string/filters'

module PrometheusExporter
  module Utils
    class SqlSanitizer
      MULTIPLE_SPACES    = %r|\s+|.freeze
      MULTIPLE_QUESTIONS = /\?(,\?)+/.freeze

      PSQL_VAR_INTERPOLATION = %r|\[\[.*\]\]\s*$|.freeze
      PSQL_REMOVE_STRINGS = /'(?:[^']|'')*'/.freeze
      PSQL_REMOVE_INTEGERS = /(?<!LIMIT )\b\d+\b/.freeze
      PSQL_PLACEHOLDER = /\$\d+/.freeze
      PSQL_IN_CLAUSE = /IN\s+\(\?[^\)]*\)/.freeze

      MYSQL_VAR_INTERPOLATION = %r|\[\[.*\]\]\s*$|.freeze
      MYSQL_REMOVE_INTEGERS = /(?<!LIMIT )\b\d+\b/.freeze
      MYSQL_REMOVE_SINGLE_QUOTE_STRINGS = %r{'(?:\\'|[^']|'')*'}.freeze
      MYSQL_REMOVE_DOUBLE_QUOTE_STRINGS = %r{"(?:\\"|[^"]|"")*"}.freeze
      MYSQL_IN_CLAUSE = /IN\s+\(\?[^\)]*\)/.freeze

      SQLITE_VAR_INTERPOLATION = %r|\[\[.*\]\]\s*$|.freeze
      SQLITE_REMOVE_STRINGS = /'(?:[^']|'')*'/.freeze
      SQLITE_REMOVE_INTEGERS = /(?<!LIMIT )\b\d+\b/.freeze

      MAX_SQL_LENGTH = 16384

      attr_accessor :database_engine

      def initialize(sql)
        @raw_sql = sql

        rails = PrometheusExporter::Utils::Rails.new
        @database_engine = rails.database_engine

        @sanitized = false # only sanitize once.
      end

      def sql
        @sql ||= scrubbed(@raw_sql.dup)
      end

      def to_s
        case database_engine
        when :postgres then to_s_postgres
        when :mysql    then to_s_mysql
        when :sqlite   then to_s_sqlite
        end
      end

      private

      def to_s_postgres
        sql.squish!
        sql.gsub!(PSQL_PLACEHOLDER, '?')
        sql.gsub!(PSQL_VAR_INTERPOLATION, '')
        sql.gsub!(PSQL_REMOVE_STRINGS, '?')
        sql.gsub!(PSQL_REMOVE_INTEGERS, '?')
        sql.gsub!(PSQL_IN_CLAUSE, 'IN (?)')
        sql.gsub!(MULTIPLE_SPACES, ' ')
        sql.strip!
        sql
      end

      def to_s_mysql
        sql.squish!
        sql.gsub!(MYSQL_VAR_INTERPOLATION, '')
        sql.gsub!(MYSQL_REMOVE_SINGLE_QUOTE_STRINGS, '?')
        sql.gsub!(MYSQL_REMOVE_DOUBLE_QUOTE_STRINGS, '?')
        sql.gsub!(MYSQL_REMOVE_INTEGERS, '?')
        sql.gsub!(MYSQL_IN_CLAUSE, 'IN (?)')
        sql.gsub!(MULTIPLE_QUESTIONS, '?')
        sql.strip!
        sql
      end

      def to_s_sqlite
        sql.squish!
        sql.gsub!(SQLITE_VAR_INTERPOLATION, '')
        sql.gsub!(SQLITE_REMOVE_STRINGS, '?')
        sql.gsub!(SQLITE_REMOVE_INTEGERS, '?')
        sql.gsub!(MULTIPLE_SPACES, ' ')
        sql.strip!
        sql
      end

      def scrubbed(str)
        return '' if !str.is_a?(String) || str.length > MAX_SQL_LENGTH
        return str if str.valid_encoding?
        return str.scrub('_')
      end
    end
  end
end