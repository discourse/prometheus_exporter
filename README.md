# Prometheus Exporter

Prometheus Exporter allows you to aggregate custom metrics from multiple processes and export to Prometheus.

It provides a very flexible framework for handling Prometheus metrics and can operate in a single and multiprocess mode.

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

Simplest way of consuming Prometheus exporter is in a single process mode, to do so:

```ruby
require 'prometheus_exporter/server'

# port is the port that will provide the /metrics route
server = PrometheusExporter::Server::WebServer.new port: 12345
server.start

gauge = PrometheusExporter::Metric::Gauge.new("rss", "used RSS for process")
counter = PrometheusExporter::Metric::Counter.new("web_requests", "number of web requests")
summary = PrometheusExporter::Metric::Summary.new("page_load_time", "time it took to load page")

server.collector.register_metric(gauge)
server.collector.register_metric(counter)
server.collector.register_metric(summary)

gauge.observe(get_rss)
gauge.observe(get_rss)

counter.observe(1, route: 'test/route')
counter.observe(1, route: 'another/route')

summary.observe(1.1)
summary.observe(1.12)
summary.observe(0.12)

# http://localhost:12345/metrics now returns all your metrics

```

### Multi process mode

In some cases, for example unicorn or puma clusters you may want to aggregate metrics across multiple processes.

Simplest way to acheive this is use the built-in collector.

First, run an exporter on your desired port, we use the default port of 9394:

```
# prometheus_exporter
```

At this point an exporter is running on port 9394

In your application:

```ruby
require 'prometheus_exporter/client'

client = PrometheusExporter::Client.default
gauge = client.register(:gauge, "awesome", "amount of awesome")

gauge.observe(10)
gauge.observe(99, day: "friday")

```

Then you will get the metrics:

```bash
% curl localhost:9394/metrics
# HELP collector_working Is the master process collector able to collect metrics
# TYPE collector_working gauge
collector_working 1

# HELP awesome amount of awesome
# TYPE awesome gauge
awesome{day="friday"} 99
awesome 10

```

### Easy integration into Rails

You can easily integrate into any Rack application:

In your Gemfile:

```
gem 'prometheus_exporter'
```


```
# in an initializer

unless Rails.env == "test"
  require 'prometheus_exporter/middleware'
  # insert in position 1
  # instrument means method profiler will be injected in Redis and PG
  Rails.application.middleware.unshift PrometheusExporter::Middleware
end
```

You may also be interested in per-process stats, this collects memory and GC stats

```
# in an initializer
unless Rails.env == "test"
  require 'prometheus_exporter/instrumentation'
  PrometheusExporter::Instrumentation::Process.start(type: "master")
end

after_fork do
  require 'prometheus_exporter/instrumentation'
  PrometheusExporter::Instrumentation::Process.start(type:"web")
end

```

Ensure you run the exporter via

```
% bundle exec prometheus_exporter
```

### Multi process mode with custom collector

You can opt for custom collector logic in a multi process environment.

This allows you better control over the amount of data transported over HTTP and also allow you to introduce custom logic into your centralized collector.

The standard collector ships "help", "type" and "name" for every metric, in some cases you may want to avoid sending all that data.

First, define a custom collector, it is critical you inherit off `PrometheusExporter::Server::Collector`, also it is critical you have custom implementations for #process and #prometheus_metrics_text

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

```bash
% bin/prometheus_exporter 12345 --collector examples/custom_collector.rb
```

In your application ship it the metrics you want:

```ruby
require 'prometheus_exporter/client'

client = PrometheusExporter::Client.new(host: 'localhost', port: 12345)
client.send_json(thing1: 122)
client.send_json(thing2: 12)
```

Now your exporter will echo the metrics:

```
% curl localhost:12345/metrics
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


## Transport concerns

Prometheus Exporter handles transport using a simple HTTP protocol. In multi process mode we avoid needing a large number of HTTP request by using chunked encoding to send metrics. This means that a single HTTP channel can deliver 100s or even 1000s of metrics over a single HTTP session to the `/send-metrics` endpoint.

The `/bench` directory has simple benchmark it is able to send through 10k messages in 500ms.


## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/discourse/prometheus_exporter. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the PrometheusExporter project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/SamSaffron/prometheus_exporter/blob/master/CODE_OF_CONDUCT.md).
