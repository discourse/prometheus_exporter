
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "prometheus_exporter/version"

Gem::Specification.new do |spec|
  spec.name          = "prometheus_exporter"
  spec.version       = PrometheusExporter::VERSION
  spec.authors       = ["Sam Saffron"]
  spec.email         = ["sam.saffron@gmail.com"]

  spec.summary       = %q{Prometheus Exporter}
  spec.description   = %q{Aggregate and forward prometheus metrics}
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features|bin)/})
  end
  spec.bindir        = "bin"
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.16"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "guard", "~> 2.0"
  spec.add_development_dependency "guard-minitest", "~> 2.0"
end
