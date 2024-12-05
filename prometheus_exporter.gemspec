# frozen_string_literal: true

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "prometheus_exporter/version"

Gem::Specification.new do |spec|
  spec.name = "prometheus_exporter"
  spec.version = PrometheusExporter::VERSION
  spec.authors = ["Sam Saffron"]
  spec.email = ["sam.saffron@gmail.com"]

  spec.summary = "Prometheus Exporter"
  spec.description = "Prometheus metric collector and exporter for Ruby"
  spec.homepage = "https://github.com/discourse/prometheus_exporter"
  spec.license = "MIT"

  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features|bin)/}) }
  spec.bindir = "bin"
  spec.executables = ["prometheus_exporter"]
  spec.require_paths = ["lib"]

  spec.add_dependency "webrick"

  spec.add_development_dependency "rubocop", ">= 0.69"
  spec.add_development_dependency "bundler", ">= 2.1.4"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.23.0"
  spec.add_development_dependency "guard", "~> 2.0"
  spec.add_development_dependency "mini_racer", "~> 0.12.0"
  spec.add_development_dependency "guard-minitest", "~> 2.0"
  spec.add_development_dependency "oj", "~> 3.0"
  spec.add_development_dependency "rack-test", "~> 2.1.0"
  spec.add_development_dependency "minitest-stub-const", "~> 0.6"
  spec.add_development_dependency "rubocop-discourse", ">= 3"
  spec.add_development_dependency "appraisal", "~> 2.3"
  spec.add_development_dependency "activerecord", "~> 6.0.0"
  spec.add_development_dependency "redis", "> 5"
  spec.add_development_dependency "m"
  spec.add_development_dependency "syntax_tree"
  spec.add_development_dependency "syntax_tree-disable_ternary"
  spec.add_development_dependency "raindrops", "~> 0.19" if !RUBY_ENGINE == "jruby"
  spec.required_ruby_version = ">= 3.0.0"
end
