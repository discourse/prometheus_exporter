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
    end
  end

  def call(env)
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
      action: action,
      controller: controller,
      status: status
    )
  end
end
