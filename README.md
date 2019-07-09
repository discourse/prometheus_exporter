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
    * [Delayed Job plugin](#delayed-job-plugin)
    * [Hutch metrics](#hutch-message-processing-tracer)
  * [Puma metrics](#puma-metrics)
  * [Unicorn metrics](#unicorn-process-metrics)
  * [Custom type collectors](#custom-type-collectors)
  * [Multi process mode with custom collector](#multi-process-mode-with-custom-collector)
  * [GraphQL support](#graphql-support)
  * [Metrics default prefix / labels](#metrics-default-prefix--labels)
  * [Client default labels](#client-default-labels)
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

# port is the port that will provide the /metrics route
server = PrometheusExporter::Server::WebServer.new port: 12345
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

First, run an exporter on your desired port (we use the default port of 9394):

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
  PrometheusExporter::Instrumentation::Process.start(type:"web")
end

```

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

#### Delayed Job plugin

In an initializer:

```ruby
unless Rails.env == "test"
  require 'prometheus_exporter/instrumentation'
  PrometheusExporter::Instrumentation::DelayedJob.register_plugin
end
```

#### Hutch Message Processing Tracer

Capture [Hutch](https://github.com/gocardless/hutch) metrics (how many jobs ran? how many failed? how long did they take?)

```ruby
unless Rails.env == "test"
  require 'prometheus_exporter/instrumentation'
  Hutch::Config.set(:tracer, PrometheusExporter::Instrumentation::Hutch)
end
```

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

### Unicorn process metrics

In order to gather metrics from unicorn processes, we use `rainbows`, which exposes `Rainbows::Linux.tcp_listener_stats` to gather information about active workers and queued requests. To start monitoring your unicorn processes, you'll need to know both the path to unicorn PID file and the listen address (`pid_file` and `listen` in your unicorn config file)

Then, run `prometheus_exporter` with `--unicorn-master` and `--unicorn-listen-address` options:

```bash
prometheus_exporter --unicorn-master /var/run/unicorn.pid --unicorn-listen-address 127.0.0.1:3000

# alternatively, if you're using unix sockets:
prometheus_exporter --unicorn-master /var/run/unicorn.pid --unicorn-listen-address /var/run/unicorn.sock
```

Note: You must install the `raindrops` gem in your `Gemfile` or locally.

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
