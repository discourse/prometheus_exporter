# frozen_string_literal: true

require_relative '../client'

module PrometheusExporter::Server
  class RunnerException < StandardError; end
  class WrongInheritance < RunnerException; end

  class Runner
    def initialize(options = {})
      @timeout = nil
      @port = nil
      @bind = nil
      @collector_class = nil
      @type_collectors = nil
      @prefix = nil
      @auth = nil
      @realm = nil
      @histogram = nil

      options.each do |k, v|
        send("#{k}=", v) if self.class.method_defined?("#{k}=")
      end
    end

    def start
      PrometheusExporter::Metric::Base.default_prefix = prefix
      PrometheusExporter::Metric::Base.default_labels = label

      if histogram
        PrometheusExporter::Metric::Base.default_aggregation = PrometheusExporter::Metric::Histogram
      end

      register_type_collectors

      unless collector.is_a?(PrometheusExporter::Server::CollectorBase)
        raise WrongInheritance, 'Collector class must be inherited from PrometheusExporter::Server::CollectorBase'
      end

      if unicorn_listen_address && unicorn_pid_file

        require_relative '../instrumentation'

        local_client = PrometheusExporter::LocalClient.new(collector: collector)
        PrometheusExporter::Instrumentation::Unicorn.start(
          pid_file: unicorn_pid_file,
          listener_address: unicorn_listen_address,
          client: local_client
        )
      end

      server = server_class.new(port: port, bind: bind, collector: collector, timeout: timeout, verbose: verbose, auth: auth, realm: realm)
      server.start
    end

    attr_accessor :unicorn_listen_address, :unicorn_pid_file
    attr_writer :prefix, :port, :bind, :collector_class, :type_collectors, :timeout, :verbose, :server_class, :label, :auth, :realm, :histogram

    def auth
      @auth || nil
    end

    def realm
      @realm || PrometheusExporter::DEFAULT_REALM
    end

    def prefix
      @prefix || PrometheusExporter::DEFAULT_PREFIX
    end

    def port
      @port || PrometheusExporter::DEFAULT_PORT
    end

    def bind
      @bind || PrometheusExporter::DEFAULT_BIND_ADDRESS
    end

    def collector_class
      @collector_class || PrometheusExporter::Server::Collector
    end

    def type_collectors
      @type_collectors || []
    end

    def timeout
      @timeout || PrometheusExporter::DEFAULT_TIMEOUT
    end

    def verbose
      return @verbose if defined? @verbose
      false
    end

    def server_class
      @server_class || PrometheusExporter::Server::WebServer
    end

    def collector
      @_collector ||= collector_class.new
    end

    def label
      @label ||= PrometheusExporter::DEFAULT_LABEL
    end

    def histogram
      @histogram || false
    end

    private

    def register_type_collectors
      type_collectors.each do |klass|
        collector.register_collector klass.new
        STDERR.puts "Registered TypeCollector: #{klass}" if verbose
      end
    end
  end
end
