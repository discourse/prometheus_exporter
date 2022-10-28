# frozen_string_literal: true

require 'prometheus_exporter/instrumentation/method_profiler'
require 'prometheus_exporter/client'

class PrometheusExporter::Middleware
  MethodProfiler = PrometheusExporter::Instrumentation::MethodProfiler

  def initialize(app, config = { instrument: :alias_method, client: nil })
    @app = app
    @client = config[:client] || PrometheusExporter::Client.default

    if config[:instrument]
      if defined?(RedisClient)
        apply_redis_client_middleware!
      end
      if defined?(Redis::VERSION) && (Gem::Version.new(Redis::VERSION) >= Gem::Version.new('5.0.0'))
        # redis 5 support handled via RedisClient
      elsif defined? Redis::Client
        MethodProfiler.patch(Redis::Client, [
          :call, :call_pipeline
        ], :redis, instrument: config[:instrument])
      end
      if defined? PG::Connection
        MethodProfiler.patch(PG::Connection, [
          :exec, :async_exec, :exec_prepared, :send_query_prepared, :query
        ], :sql, instrument: config[:instrument])
      end
      if defined? Mysql2::Client
        MethodProfiler.patch(Mysql2::Client, [:query], :sql, instrument: config[:instrument])
        MethodProfiler.patch(Mysql2::Statement, [:execute], :sql, instrument: config[:instrument])
        MethodProfiler.patch(Mysql2::Result, [:each], :sql, instrument: config[:instrument])
      end
    end
  end

  def call(env)
    queue_time = measure_queue_time(env)

    MethodProfiler.start
    result = @app.call(env)
    info = MethodProfiler.stop

    result
  ensure
    status = (result && result[0]) || -1
    obj = {
      type: "web",
      timings: info,
      queue_time: queue_time,
      status: status,
      default_labels: default_labels(env, result)
    }
    labels = custom_labels(env)
    if labels
      obj = obj.merge(custom_labels: labels)
    end

    @client.send_json(obj)
  end

  def default_labels(env, result)
    params = env["action_dispatch.request.parameters"]
    action = controller = nil
    if params
      action = params["action"]
      controller = params["controller"]
    elsif (cors = env["rack.cors"]) && cors.respond_to?(:preflight?) && cors.preflight?
      # if the Rack CORS Middleware identifies the request as a preflight request,
      # the stack doesn't get to the point where controllers/actions are defined
      action = "preflight"
      controller = "preflight"
    end

    {
      action: action || "other",
      controller: controller || "other"
    }
  end

  # allows subclasses to add custom labels based on env
  def custom_labels(env)
    nil
  end

  private

  # measures the queue time (= time between receiving the request in downstream
  # load balancer and starting request in ruby process)
  def measure_queue_time(env)
    start_time = queue_start(env)

    return unless start_time

    queue_time = request_start.to_f - start_time.to_f
    queue_time unless queue_time.negative?
  end

  # need to use CLOCK_REALTIME, as nginx/apache write this also out as the unix timestamp
  def request_start
    Process.clock_gettime(Process::CLOCK_REALTIME)
  end

  # determine queue start from well-known trace headers
  def queue_start(env)

    # get the content of the x-queue-start or x-request-start header
    value = env['HTTP_X_REQUEST_START'] || env['HTTP_X_QUEUE_START']
    unless value.nil? || value == ''
      # nginx returns time as milliseconds with 3 decimal places
      # apache returns time as microseconds without decimal places
      # this method takes care to convert both into a proper second + fractions timestamp
      value = value.to_s.gsub(/t=|\./, '')
      return "#{value[0, 10]}.#{value[10, 13]}".to_f
    end

    # get the content of the x-amzn-trace-id header
    # see also: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-request-tracing.html
    value = env['HTTP_X_AMZN_TRACE_ID']
    value&.split('Root=')&.last&.split('-')&.fetch(1)&.to_i(16)

  end

  private

  module RedisInstrumenter
    MethodProfiler.define_methods_on_module(self, ["call", "call_pipelined"], "redis")
  end

  def apply_redis_client_middleware!
    RedisClient.register(RedisInstrumenter)
  end

end
