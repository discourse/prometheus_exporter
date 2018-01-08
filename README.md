# PrometheusExporter

PrometheusExporter allows you to aggregate custom metrics from multiple processes and export to Prometheus.

Unlike PushGateway it is designed to perform transformations and aggregations on the metrics it collects.

It can be used when a single "logical" process has multiple "workers" processes that gather metrics.
For example: unicorn workers may wish to export information about the number of requests made and so on.

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

TODO: Write usage instructions here

## Development

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/SamSaffron/prometheus_exporter. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the PrometheusExporter project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/SamSaffron/prometheus_exporter/blob/master/CODE_OF_CONDUCT.md).
