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
  spec.bindir = "exe"
  spec.executables = ["prometheus_exporter"]
  spec.require_paths = ["lib"]

  spec.add_dependency "webrick"

  spec.required_ruby_version = ">= 3.0.0"
end
