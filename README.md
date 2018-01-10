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

First, run an exporter on your desired port:

```
# prometheus_exporter 12345
```

At this point an exporter is running on port 12345

In your application:

```ruby
require 'prometheus_exporter/client'

client = PrometheusExporter::Client.new(host: 'localhost', port: 12345)
gauge = client.register(:gauge, "awesome", "amount of awesome")

gauge.observe(10)
gauge.observe(99, day: "friday")

```

Then you will get the metrics:

```bash
% curl localhost:12345/metrics
# HELP collector_working Is the master process collector able to collect metrics
# TYPE collector_working gauge
collector_working 1

# HELP awesome amount of awesome
# TYPE awesome gauge
awesome{day="friday"} 99
awesome 10

```


## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/SamSaffron/prometheus_exporter. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the PrometheusExporter project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/SamSaffron/prometheus_exporter/blob/master/CODE_OF_CONDUCT.md).
