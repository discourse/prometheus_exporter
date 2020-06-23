# Prometheus Exporter

Prometheus Exporter allows you to aggregate custom metrics from multiple processes and export to Prometheus. It provides a very flexible framework for handling Prometheus metrics and can operate in a single and multiprocess mode.

To learn more see [Instrumenting Rails with Prometheus](https://samsaffron.com/archive/2018/02/02/instrumenting-rails-with-prometheus) (it has pretty pictures!)

* [Requirements](#requirements)
* [Installation](#installation)
* [Usage](#usage)
  * [Single process mode](#single-process-mode)
    * [Custom quantiles and buckets](#custom-quantiles-and-buckets)
  * [Multi process mode](#multi-process-mode)
  * [Rails integration](#rails-integration)
    * [Per-process stats](#per-process-stats)
    * [Sidekiq metrics](#sidekiq-metrics)
    * [Shoryuken metrics](#shoryuken-metrics)
    * [ActiveRecord Connection Pool Metrics](#activerecord-connection-pool-metrics)
    * [Delayed Job plugin](#delayed-job-plugin)
    * [Hutch metrics](#hutch-message-processing-tracer)
  * [Puma metrics](#puma-metrics)
  * [Unicorn metrics](#unicorn-process-metrics)
  * [Custom type collectors](#custom-type-collectors)
  * [Multi process mode with custom collector](#multi-process-mode-with-custom-collector)
  * [GraphQL support](#graphql-support)
  * [Metrics default prefix / labels](#metrics-default-prefix--labels)
  * [Client default labels](#client-default-labels)
  * [Client default host](#client-default-host)
* [Transport concerns](#transport-concerns)
* [JSON generation and parsing](#json-generation-and-parsing)
* [Contributing](#contributing)
* [License](#license)
* [Code of Conduct](#code-of-conduct)

## Requirements

Minimum Ruby of version 2.3.0 is required, Ruby 2.2.0 is EOL as of 2018-03-31

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'prometheus_exporter'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install prometheus_exporter

## Usage

### Single process mode

Simplest way of consuming Prometheus exporter is in a single process mode.

```ruby
require 'prometheus_exporter/server'

# client allows instrumentation to send info to server
require 'prometheus_exporter/client'
require 'prometheus_exporter/instrumentation'

# bind is the address, on which the webserver will listen
# port is the port that will provide the /metrics route
server = PrometheusExporter::Server::WebServer.new bind: 'localhost', port: 12345
server.start

# wire up a default local client
PrometheusExporter::Client.default = PrometheusExporter::LocalClient.new(collector: server.collector)

# this ensures basic process instrumentation metrics are added such as RSS and Ruby metrics
PrometheusExporter::Instrumentation::Process.start(type: "my program", labels: {my_custom: "label for all process metrics"})

gauge = PrometheusExporter::Metric::Gauge.new("rss", "used RSS for process")
counter = PrometheusExporter::Metric::Counter.new("web_requests", "number of web requests")
summary = PrometheusExporter::Metric::Summary.new("page_load_time", "time it took to load page")
histogram = PrometheusExporter::Metric::Histogram.new("api_access_time", "time it took to call api")

server.collector.register_metric(gauge)
server.collector.register_metric(counter)
server.collector.register_metric(summary)
server.collector.register_metric(histogram)

gauge.observe(get_rss)
gauge.observe(get_rss)

counter.observe(1, route: 'test/route')
counter.observe(1, route: 'another/route')

summary.observe(1.1)
summary.observe(1.12)
summary.observe(0.12)

histogram.observe(0.2, api: 'twitter')

# http://localhost:12345/metrics now returns all your metrics

```

#### Custom quantiles and buckets

You can also choose custom quantiles for summaries and custom buckets for histograms.

```ruby

summary = PrometheusExporter::Metric::Summary.new("load_time", "time to load page", quantiles: [0.99, 0.75, 0.5, 0.25])
histogram = PrometheusExporter::Metric::Histogram.new("api_time", "time to call api", buckets: [0.1, 0.5, 1])

```

### Multi process mode

In some cases (for example, unicorn or puma clusters) you may want to aggregate metrics across multiple processes.

Simplest way to achieve this is to use the built-in collector.

First, run an exporter on your desired port (we use the default bind to localhost and port of 9394):

```
$ prometheus_exporter
```

And in your application:

```ruby
require 'prometheus_exporter/client'

client = PrometheusExporter::Client.default
gauge = client.register(:gauge, "awesome", "amount of awesome")

gauge.observe(10)
gauge.observe(99, day: "friday")

```

Then you will get the metrics:

```
$ curl localhost:9394/metrics
# HELP collector_working Is the master process collector able to collect metrics
# TYPE collector_working gauge
collector_working 1

# HELP awesome amount of awesome
# TYPE awesome gauge
awesome{day="friday"} 99
awesome 10

```

Custom quantiles for summaries and buckets for histograms can also be passed in.

```ruby
require 'prometheus_exporter/client'

client = PrometheusExporter::Client.default
histogram = client.register(:histogram, "api_time", "time to call api", buckets: [0.1, 0.5, 1])

histogram.observe(0.2, api: 'twitter')
```

### Rails integration

You can easily integrate into any Rack application.

In your Gemfile:

```ruby
gem 'prometheus_exporter'
```

In an initializer:

```ruby
unless Rails.env == "test"
  require 'prometheus_exporter/middleware'

  # This reports stats per request like HTTP status and timings
  Rails.application.middleware.unshift PrometheusExporter::Middleware
end
```

Ensure you run the exporter in a monitored background process:

```
$ bundle exec prometheus_exporter
```

#### Metrics collected by Rails integration middleware

| Type    | Name                            | Description                                                 |
| ---     | ---                             | ---                                                         |
| Counter | `http_requests_total`           | Total HTTP requests from web app                            |
| Summary | `http_duration_seconds`         | Time spent in HTTP reqs in seconds                          |
| Summary | `http_redis_duration_seconds`¹  | Time spent in HTTP reqs in Redis, in seconds                |
| Summary | `http_sql_duration_seconds`²    | Time spent in HTTP reqs in SQL in seconds                   |
| Summary | `http_queue_duration_seconds`³  | Time spent queueing the request in load balancer in seconds |

All metrics have a `controller` and an `action` label.  
`http_requests_total` additionally has a (HTTP response) `status` label.  

¹) Only available when Redis is used.  
²) Only available when Mysql or PostgreSQL are used.  
³) Only available when [Instrumenting Request Queueing Time](#instrumenting-request-queueing-time) is set up.  

#### Activerecord Connection Pool Metrics

This collects activerecord connection pool metrics.

It supports injection of custom labels and the connection config options (`username`, `database`, `host`, `port`) as labels.

For Puma single mode
```ruby
#in puma.rb
require 'prometheus_exporter/instrumentation'
PrometheusExporter::Instrumentation::ActiveRecord.start(
  custom_labels: { type: "puma_single_mode" }, #optional params
  config_labels: [:database, :host] #optional params
)
```

For Puma cluster mode

```ruby
# in puma.rb
on_worker_boot do
  require 'prometheus_exporter/instrumentation'
  PrometheusExporter::Instrumentation::ActiveRecord.start(
    custom_labels: { type: "puma_worker" }, #optional params
    config_labels: [:database, :host] #optional params
  )
end
```

For Unicorn / Passenger

```ruby
after_fork do |_server, _worker|
  require 'prometheus_exporter/instrumentation'
  PrometheusExporter::Instrumentation::ActiveRecord.start(
    custom_labels: { type: "unicorn_worker" }, #optional params
    config_labels: [:database, :host] #optional params
  )
end
```

For Sidekiq
```ruby
Sidekiq.configure_server do |config|
  config.on :startup do
    require 'prometheus_exporter/instrumentation'
    PrometheusExporter::Instrumentation::ActiveRecord.start(
      custom_labels: { type: "sidekiq" }, #optional params
      config_labels: [:database, :host] #optional params
    )
  end
end
```

##### Metrics collected by ActiveRecord Instrumentation

| Type  | Name                                        | Description                           |
| ---   | ---                                         | ---                                   |
| Gauge | `active_record_connection_pool_connections` | Total connections in pool             |
| Gauge | `active_record_connection_pool_busy`        | Connections in use in pool            |
| Gauge | `active_record_connection_pool_dead`        | Dead connections in pool              |
| Gauge | `active_record_connection_pool_idle`        | Idle connections in pool              |
| Gauge | `active_record_connection_pool_waiting`     | Connection requests waiting           |
| Gauge | `active_record_connection_pool_size`        | Maximum allowed connection pool size  |

All metrics collected by the ActiveRecord integration include at least the following labels: `pid` (of the process the stats where collected in), `pool_name`, any labels included in the `config_labels` option (prefixed with `dbconfig_`, example: `dbconfig_host`), and all custom labels provided with the `custom_labels` option.

#### Per-process stats

You may also be interested in per-process stats. This collects memory and GC stats:

```ruby
# in an initializer
unless Rails.env == "test"
  require 'prometheus_exporter/instrumentation'

  # this reports basic process stats like RSS and GC info
  PrometheusExporter::Instrumentation::Process.start(type: "master")
end

# in unicorn/puma/passenger be sure to run a new process instrumenter after fork
after_fork do
  require 'prometheus_exporter/instrumentation'
  PrometheusExporter::Instrumentation::Process.start(type: "web")
end

```

##### Metrics collected by Process Instrumentation

| Type    | Name                      | Description                                  |
| ---     | ---                       | ---                                          |
| Gauge   | `heap_free_slots`         | Free ruby heap slots                         |
| Gauge   | `heap_live_slots`         | Used ruby heap slots                         |
| Gauge   | `v8_heap_size`*           | Total JavaScript V8 heap size (bytes)        |
| Gauge   | `v8_used_heap_size`*      | Total used JavaScript V8 heap size (bytes)   |
| Gauge   | `v8_physical_size`*       | Physical size consumed by V8 heaps           |
| Gauge   | `v8_heap_count`*          | Number of V8 contexts running                |
| Gauge   | `rss`                     | Total RSS used by process                    |
| Counter | `major_gc_ops_total`      | Major GC operations by process               |
| Counter | `minor_gc_ops_total`      | Minor GC operations by process               |
| Counter | `allocated_objects_total` | Total number of allocated objects by process |

_Metrics marked with * are only collected when `MiniRacer` is defined._

Metrics collected by Process instrumentation include labels `type` (as given with the `type` option), `pid` (of the process the stats where collected in), and any custom labels given to `Process.start` with the `labels` option.

#### Sidekiq metrics

Including Sidekiq metrics (how many jobs ran? how many failed? how long did they take? how many are dead? how many were restarted?)

```ruby
Sidekiq.configure_server do |config|
   config.server_middleware do |chain|
      require 'prometheus_exporter/instrumentation'
      chain.add PrometheusExporter::Instrumentation::Sidekiq
   end
   config.death_handlers << PrometheusExporter::Instrumentation::Sidekiq.death_handler
end
```

To monitor Queue size and latency:

```ruby
Sidekiq.configure_server do |config|
  config.on :startup do
    require 'prometheus_exporter/instrumentation'
    PrometheusExporter::Instrumentation::SidekiqQueue.start
  end
end
```

To monitor Sidekiq process info:

```ruby
Sidekiq.configure_server do |config|
  config.on :startup do
    require 'prometheus_exporter/instrumentation'
    PrometheusExporter::Instrumentation::Process.start type: 'sidekiq'
  end
end
```

Sometimes the Sidekiq server shuts down before it can send metrics, that were generated right before the shutdown, to the collector. Especially if you care about the `sidekiq_restarted_jobs_total` metric, it is a good idea to explicitly stop the client:

```ruby
  Sidekiq.configure_server do |config|
    at_exit do
      PrometheusExporter::Client.default.stop(wait_timeout_seconds: 10)
    end
  end
```

##### Metrics collected by Sidekiq Instrumentation

**PrometheusExporter::Instrumentation::Sidekiq**
| Type    | Name                           | Description                                                                  |
| ---     | ---                            | ---                                                                          |
| Counter | `sidekiq_job_duration_seconds` | Total time spent in sidekiq jobs                                             |
| Counter | `sidekiq_jobs_total`           | Total number of sidekiq jobs executed                                        |
| Counter | `sidekiq_restarted_jobs_total` | Total number of sidekiq jobs that we restarted because of a sidekiq shutdown |
| Counter | `sidekiq_failed_jobs_total`    | Total number of failed sidekiq jobs                                          |

All metrics have a `job_name` label.

**PrometheusExporter::Instrumentation::Sidekiq.death_handler**
| Type    | Name                      | Description                       |
| ---     | ---                       | ---                               |
| Counter | `sidekiq_dead_jobs_total` | Total number of dead sidekiq jobs |

This metric also has a `job_name` label.

**PrometheusExporter::Instrumentation::SidekiqQueue**
| Type  | Name                            | Description                  |
| ---   | ---                             | ---                          |
| Gauge | `sidekiq_queue_backlog_total`   | Size of the sidekiq queue    |
| Gauge | `sidekiq_queue_latency_seconds` | Latency of the sidekiq queue |

Both metrics will have a `queue` label with the name of the queue.

_See [Metrics collected by Process Instrumentation](#metrics-collected-by-process-instrumentation) for a list of metrics the Process instrumentation will produce._  

#### Shoryuken metrics

For Shoryuken metrics (how many jobs ran? how many failed? how long did they take? how many were restarted?)

```ruby
Shoryuken.configure_server do |config|
  config.server_middleware do |chain|
    require 'prometheus_exporter/instrumentation'
    chain.add PrometheusExporter::Instrumentation::Shoryuken
  end
end
```

##### Metrics collected by Shoryuken Instrumentation

| Type    | Name                             | Description                                                                      |
| ---     | ---                              | ---                                                                              |
| Counter | `shoryuken_job_duration_seconds` | Total time spent in shoryuken jobs                                               |
| Counter | `shoryuken_jobs_total`           | Total number of shoryuken jobs executed                                          |
| Counter | `shoryuken_restarted_jobs_total` | Total number of shoryuken jobs that we restarted because of a shoryuken shutdown |
| Counter | `shoryuken_failed_jobs_total`    | Total number of failed shoryuken jobs                                            |

All metrics have labels for `job_name` and `queue_name`.  

#### Delayed Job plugin

In an initializer:

```ruby
unless Rails.env == "test"
  require 'prometheus_exporter/instrumentation'
  PrometheusExporter::Instrumentation::DelayedJob.register_plugin
end
```

##### Metrics collected by Delayed Job Instrumentation

| Type    | Name                                      | Description                                                        | Labels     |
| ---     | ---                                       | ---                                                                | ---        |
| Counter | `delayed_job_duration_seconds`            | Total time spent in delayed jobs                                   | `job_name` |
| Counter | `delayed_jobs_total`                      | Total number of delayed jobs executed                              | `job_name` |
| Gauge   | `delayed_jobs_enqueued`                   | Number of enqueued delayed jobs                                    | -          |
| Gauge   | `delayed_jobs_pending`                    | Number of pending delayed jobs                                     | -          |
| Counter | `delayed_failed_jobs_total`               | Total number failed delayed jobs executed                          | `job_name` |
| Counter | `delayed_jobs_max_attempts_reached_total` | Total number of delayed jobs that reached max attempts             | -          |
| Summary | `delayed_job_duration_seconds_summary`    | Summary of the time it takes jobs to execute                       | `status`   |
| Summary | `delayed_job_attempts_summary`            | Summary of the amount of attempts it takes delayed jobs to succeed | -          |

#### Hutch Message Processing Tracer

Capture [Hutch](https://github.com/gocardless/hutch) metrics (how many jobs ran? how many failed? how long did they take?)

```ruby
unless Rails.env == "test"
  require 'prometheus_exporter/instrumentation'
  Hutch::Config.set(:tracer, PrometheusExporter::Instrumentation::Hutch)
end
```

##### Metrics collected by Hutch Instrumentation

| Type    | Name                         | Description                             |
| ---     | ---                          | ---                                     |
| Counter | `hutch_job_duration_seconds` | Total time spent in hutch jobs          |
| Counter | `hutch_jobs_total`           | Total number of hutch jobs executed     |
| Counter | `hutch_failed_jobs_total`    | Total number failed hutch jobs executed |

All metrics have a `job_name` label. 

#### Instrumenting Request Queueing Time

Request Queueing is defined as the time it takes for a request to reach your application (instrumented by this `prometheus_exporter`) from farther upstream (as your load balancer). A high queueing time usually means that your backend cannot handle all the incoming requests in time, so they queue up (= you should see if you need to add more capacity).

As this metric starts before `prometheus_exporter` can handle the request, you must add a specific HTTP header as early in your infrastructure as possible (we recommend your load balancer or reverse proxy).

Configure your HTTP server / load balancer to add a header `X-Request-Start: t=<MSEC>` when passing the request upstream. For more information, please consult your software manual.

Hint: we aim to be API-compatible with the big APM solutions, so if you've got requests queueing time configured for them, it should be expected to also work with `prometheus_exporter`.

### Puma metrics

The puma metrics are using the `Puma.stats` method and hence need to be started after the
workers has been booted and from a Puma thread otherwise the metrics won't be accessible.
The easiest way to gather this metrics is to put the following in your `puma.rb` config:

```ruby
# puma.rb config
after_worker_boot do
  require 'prometheus_exporter/instrumentation'
  PrometheusExporter::Instrumentation::Puma.start
end
```

#### Metrics collected by Puma Instrumentation

| Type  | Name                              | Description                                                 |
| ---   | ---                               | ---                                                         |
| Gauge | `puma_workers_total`              | Number of puma workers                                      |
| Gauge | `puma_booted_workers_total`       | Number of puma workers booted                               |
| Gauge | `puma_old_workers_total`          | Number of old puma workers                                  |
| Gauge | `puma_running_threads_total`      | Number of puma threads currently running                    |
| Gauge | `puma_request_backlog_total`      | Number of requests waiting to be processed by a puma thread |
| Gauge | `puma_thread_pool_capacity_total` | Number of puma threads available at current scale           |
| Gauge | `puma_max_threads_total`          | Number of puma threads at available at max scale            |

All metrics may have a `phase` label.   

### Unicorn process metrics

In order to gather metrics from unicorn processes, we use `rainbows`, which exposes `Rainbows::Linux.tcp_listener_stats` to gather information about active workers and queued requests. To start monitoring your unicorn processes, you'll need to know both the path to unicorn PID file and the listen address (`pid_file` and `listen` in your unicorn config file)

Then, run `prometheus_exporter` with `--unicorn-master` and `--unicorn-listen-address` options:

```bash
prometheus_exporter --unicorn-master /var/run/unicorn.pid --unicorn-listen-address 127.0.0.1:3000

# alternatively, if you're using unix sockets:
prometheus_exporter --unicorn-master /var/run/unicorn.pid --unicorn-listen-address /var/run/unicorn.sock
```

Note: You must install the `raindrops` gem in your `Gemfile` or locally.

#### Metrics collected by Unicorn Instrumentation

| Type  | Name                            | Description                                                    |
| ---   | ---                             | ---                                                            |
| Gauge | `unicorn_workers_total`         | Number of unicorn workers                                      |
| Gauge | `unicorn_active_workers_total`  | Number of active unicorn workers                               |
| Gauge | `unicorn_request_backlog_total` | Number of requests waiting to be processed by a unicorn worker |

### Custom type collectors

In some cases you may have custom metrics you want to ship the collector in a batch. In this case you may still be interested in the base collector behavior, but would like to add your own special messages.

```ruby
# person_collector.rb
class PersonCollector < PrometheusExporter::Server::TypeCollector
  def initialize
    @oldies = PrometheusExporter::Metric::Counter.new("oldies", "old people")
    @youngies = PrometheusExporter::Metric::Counter.new("youngies", "young people")
  end

  def type
    "person"
  end

  def collect(obj)
    if obj["age"] > 21
      @oldies.observe(1)
    else
      @youngies.observe(1)
    end
  end

  def metrics
    [@oldies, @youngies]
  end
end
```

Shipping metrics then is done via:

```ruby
PrometheusExporter::Client.default.send_json(type: "person", age: 40)
```

To load the custom collector run:

```
$ bundle exec prometheus_exporter -a person_collector.rb
```

#### Global metrics in a custom type collector

Custom type collectors are the ideal place to collect global metrics, such as user/article counts and connection counts. The custom type collector runs in the collector, which usually runs in the prometheus exporter process.

Out-of-the-box we try to keep the prometheus exporter as lean as possible. We do not load all Rails dependencies, so you won't have access to your models. You can always ensure it is loaded in your custom type collector with:

```ruby
unless defined? Rails
  require File.expand_path("../../config/environment", __FILE__)
end
```

Then you can collect the metrics you need on demand:

```ruby
def metrics
  user_count_gague = PrometheusExporter::Metric::Gauge.new('user_count', 'number of users in the app')
  user_count_gague.observe User.count
  [user_count_gauge]
end
```

The metrics endpoint is called whenever prometheus calls the `/metrics` HTTP endpoint, so it may make sense to introduce some type of caching. [lru_redux](https://github.com/SamSaffron/lru_redux) is the perfect gem for this job: you can use `LruRedux::TTL::Cache`, which will expire automatically after N seconds, thus saving multiple database queries.

### Multi process mode with custom collector

You can opt for custom collector logic in a multi process environment.

This allows you to completely replace the collector logic.

First, define a custom collector. It is important that you inherit off `PrometheusExporter::Server::CollectorBase` and have custom implementations for `#process` and `#prometheus_metrics_text` methods.

```ruby
class MyCustomCollector < PrometheusExporter::Server::CollectorBase
  def initialize
    @gauge1 = PrometheusExporter::Metric::Gauge.new("thing1", "I am thing 1")
    @gauge2 = PrometheusExporter::Metric::Gauge.new("thing2", "I am thing 2")
    @mutex = Mutex.new
  end

  def process(str)
    obj = JSON.parse(str)
    @mutex.synchronize do
      if thing1 = obj["thing1"]
        @gauge1.observe(thing1)
      end

      if thing2 = obj["thing2"]
        @gauge2.observe(thing2)
      end
    end
  end

  def prometheus_metrics_text
    @mutex.synchronize do
      "#{@gauge1.to_prometheus_text}\n#{@gauge2.to_prometheus_text}"
    end
  end
end
```

Next, launch the exporter process:

```
$ bin/prometheus_exporter --collector examples/custom_collector.rb
```

In your application send metrics you want:

```ruby
require 'prometheus_exporter/client'

client = PrometheusExporter::Client.new(host: 'localhost', port: 12345)
client.send_json(thing1: 122)
client.send_json(thing2: 12)
```

Now your exporter will echo the metrics:

```
$ curl localhost:12345/metrics
# HELP collector_working Is the master process collector able to collect metrics
# TYPE collector_working gauge
collector_working 1

# HELP thing1 I am thing 1
# TYPE thing1 gauge
thing1 122

# HELP thing2 I am thing 2
# TYPE thing2 gauge
thing2 12
```

### GraphQL support

GraphQL execution metrics are [supported](https://github.com/rmosolgo/graphql-ruby/blob/master/guides/queries/tracing.md#prometheus) and can be collected via the GraphQL collector, included in [graphql-ruby](https://github.com/rmosolgo/graphql-ruby).

### Metrics default prefix / labels

_This only works in single process mode._

You can specify default prefix or labels for metrics. For example:

```ruby
# Specify prefix for metric names
PrometheusExporter::Metric::Base.default_prefix = "ruby"

# Specify default labels for metrics
PrometheusExporter::Metric::Base.default_labels = { "hostname" => "app-server-01" }

counter = PrometheusExporter::Metric::Counter.new("web_requests", "number of web requests")

counter.observe(1, route: 'test/route')
counter.observe
```

Will result in:

```
# HELP web_requests number of web requests
# TYPE web_requests counter
ruby_web_requests{hostname="app-server-01",route="test/route"} 1
ruby_web_requests{hostname="app-server-01"} 1
```

### Exporter Process Configuration

When running the process for `prometheus_exporter` using `bin/prometheus_exporter`, there are several configurations that
can be passed in:

The following will run the process at
- Port `8080` (default `9394`)
- Bind to `0.0.0.0` (default `localhost`)
- Timeout in `1 second` for metrics endpoint (default `2 seconds`)
- Metric prefix as `foo_` (default `ruby_`)
- Default labels as `{environment: "integration", foo: "bar"}`

```bash
prometheus_exporter -p 8080 \
                    -b 0.0.0.0 \
                    -t 1 \
                    --label '{"environment": "integration", "foo": "bar"}' \
                    --prefix 'foo_'
```

### Client default labels

You can specify a default label for instrumentation metrics sent by a specific client. For example:

```ruby
# Specify on intializing PrometheusExporter::Client
PrometheusExporter::Client.new(custom_labels: { hostname: 'app-server-01', app_name: 'app-01' })

# Specify on an instance of PrometheusExporter::Client
client = PrometheusExporter::Client.new
client.custom_labels = { hostname: 'app-server-01', app_name: 'app-01' }
```

Will result in:

```
http_requests_total{controller="home","action"="index",service="app-server-01",app_name="app-01"} 2
http_requests_total{service="app-server-01",app_name="app-01"} 1
```
### Client default host

By default, `PrometheusExporter::Client.default` connects to `localhost:9394`. If your setup requires this (e.g. when using `docker-compose`), you can change the default host and port by setting the environment variables `PROMETHEUS_EXPORTER_HOST` and `PROMETHEUS_EXPORTER_PORT`.

## Transport concerns

Prometheus Exporter handles transport using a simple HTTP protocol. In multi process mode we avoid needing a large number of HTTP request by using chunked encoding to send metrics. This means that a single HTTP channel can deliver 100s or even 1000s of metrics over a single HTTP session to the `/send-metrics` endpoint. All calls to `send` and `send_json` on the `PrometheusExporter::Client` class are **non-blocking** and batched.

The `/bench` directory has simple benchmark, which is able to send through 10k messages in 500ms.

## JSON generation and parsing

The `PrometheusExporter::Client` class has the method `#send-json`. This method, by default, will call `JSON.dump` on the Object it recieves. You may opt in for `oj` mode where it can use the faster `Oj.dump(obj, mode: :compat)` for JSON serialization. But be warned that if you have custom objects that implement own `to_json` methods this may not work as expected. You can opt for oj serialization with `json_serializer: :oj`.

When `PrometheusExporter::Server::Collector` parses your JSON, by default it will use the faster Oj deserializer if available. This happens cause it only expects a simple Hash out of the box. You can opt in for the default JSON deserializer with `json_serializer: :json`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/discourse/prometheus_exporter. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the PrometheusExporter project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/discourse/prometheus_exporter/blob/master/CODE_OF_CONDUCT.md).
