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

## Can I have some pretty pictures please? 

Sure, check out: [Instrumenting Rails with Prometheus](https://samsaffron.com/archive/2018/02/02/instrumenting-rails-with-prometheus)

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

  # This reports stats per request like HTTP status and timings
  Rails.application.middleware.unshift PrometheusExporter::Middleware
end
```

You may also be interested in per-process stats, this collects memory and GC stats

```
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

Including Sidekiq metrics (how many jobs ran? how many failed? how long did they take?)

```
Sidekiq.configure_server do |config|
   config.server_middleware do |chain|
      require 'prometheus_exporter/instrumentation'
      chain.add PrometheusExporter::Instrumentation::Sidekiq
   end
end
```

Ensure you run the exporter in a monitored background process via

```
% bundle exec prometheus_exporter
```

### Custom type collectors

In some cases you may have custom metrics you want to ship the collector in a batch, in this case you may still be interested in the base collector behavior but would like to add your own special messages.

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

```
PrometheusExporter::Client.default.send_json(type: "person", age: 40)
```

To load the custom collector run:


```
bundle exec prometheus_exporter -a person_collector.rb

```

#### Global metrics in a custom type collector

Custom type collectors are the ideal place to collect global metrics, such as user/article counts and connection counts. The custom type collector runs in the collector which usually runs in the prometheus exporter process. 

Out-of-the-box we try to keep the prometheus exporter as lean as possible, we do not load all the Rails dependencies so you will not have access to your models. You can always ensure it is loaded in your custom type collector with:

```
unless defined? Rails
  require File.expand_path("../../config/environment", __FILE__)
end
```

Then you can collect the metrics you need on demand:

```
def metrics 
  user_count_gague = PrometheusExporter::Metric::Gauge.new('user_count', 'number of users in the app')
  user_count_gague.observe User.count
  [user_count_gauge]
end
```

The metrics endpoint is called whenever prometheus calls the `/metrics` HTTP endpoint, it may make sense to introduce some caching so database calls are only performed once every N seconds. [lru_redux](https://github.com/SamSaffron/lru_redux) is the perfect gem for that kind of job as you can `LruRedux::TTL::Cache` which will automatically expire after N seconds. 


### Multi process mode with custom collector

You can opt for custom collector logic in a multi process environment.

This allows you to completely replace the collector logic.

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
% bin/prometheus_exporter --collector examples/custom_collector.rb
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

Prometheus Exporter handles transport using a simple HTTP protocol. In multi process mode we avoid needing a large number of HTTP request by using chunked encoding to send metrics. This means that a single HTTP channel can deliver 100s or even 1000s of metrics over a single HTTP session to the `/send-metrics` endpoint. All calls to `send` and `send_json` on the PrometheusExporter::Client class are **non-blocking** and batched. 

The `/bench` directory has simple benchmark it is able to send through 10k messages in 500ms.

## JSON generation and parsing

The `PrometheusExporter::Client` class has the method `#send-json`. This method, by default, will call `JSON.dump` on the Object it recieves. You may opt in for `oj` mode where it can use the faster `Oj.dump(obj, mode: :compat)` for JSON serialization. But be warned that if you have custom objects that implement own `to_json` methods this may not work as expected. You can opt for oj serialization with `json_serializer: :oj`

The `PrometheusExporter::Server::Collector` parses your JSON, by default it will use the faster Oj deserializer if availabe. This happens cause it only expects a simple Hash out of the box. You can opt in for the default JSON deserializer with `json_serializer: :json`

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/discourse/prometheus_exporter. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the PrometheusExporter project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/SamSaffron/prometheus_exporter/blob/master/CODE_OF_CONDUCT.md).
