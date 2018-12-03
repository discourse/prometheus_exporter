# frozen_string_literal: true

require 'prometheus_exporter/instrumentation/method_profiler'
require 'prometheus_exporter/client'

class PrometheusExporter::Middleware
  MethodProfiler = PrometheusExporter::Instrumentation::MethodProfiler

  def initialize(app, config = { instrument: true, client: nil })
    @app = app
    @client = config[:client] || PrometheusExporter::Client.default

    if config[:instrument]
      if defined? Redis::Client
        MethodProfiler.patch(Redis::Client, [:call, :call_pipeline], :redis)
      end
      if defined? PG::Connection
        MethodProfiler.patch(PG::Connection, [
          :exec, :async_exec, :exec_prepared, :send_query_prepared, :query
        ], :sql)
      end
      if defined? Mysql2::Client
        MethodProfiler.patch(Mysql2::Client, [:query], :sql)
        MethodProfiler.patch(Mysql2::Statement, [:execute], :sql)
        MethodProfiler.patch(Mysql2::Result, [:each], :sql)
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
    params = env["action_dispatch.request.parameters"]
    action, controller = nil
    if params
      action = params["action"]
      controller = params["controller"]
    end

    @client.send_json(
      type: "web",
      timings: info,
      queue_time: queue_time,
      action: action,
      controller: controller,
      status: status
    )
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

  # get the content of the x-queue-start or x-request-start header
  def queue_start(env)
    value = env['HTTP_X_REQUEST_START'] || env['HTTP_X_QUEUE_START']
    unless value.nil? || value == ''
      convert_header_to_ms(value.to_s)
    end
  end

  # nginx returns time as milliseconds with 3 decimal places
  # apache returns time as microseconds without decimal places
  # this method takes care to convert both into a proper second + fractions timestamp
  def convert_header_to_ms(str)
    str = str.gsub(/t=|\./, '')
    "#{str[0, 10]}.#{str[10, 13]}".to_f
  end
end
