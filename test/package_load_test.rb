# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/prometheus_exporter"
require "bundler"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class PrometheusExporterPackageLoadTest < Minitest::Test
  def test_built_gem_loads_with_only_its_declared_dependencies
    Dir.mktmpdir("prometheus-exporter-package") do |directory|
      package = File.join(directory, "prometheus_exporter.gem")
      gem_home = File.join(directory, "gems")
      run!(
        {},
        RbConfig.ruby,
        "-S",
        "gem",
        "build",
        "prometheus_exporter.gemspec",
        "--output",
        package,
      )
      run!(
        { "GEM_HOME" => gem_home, "GEM_PATH" => gem_home },
        RbConfig.ruby,
        "-S",
        "gem",
        "install",
        package,
        "--install-dir",
        gem_home,
        "--bindir",
        File.join(directory, "bin"),
        "--no-document",
      )

      stdout =
        run!({ "GEM_HOME" => gem_home, "GEM_PATH" => gem_home }, RbConfig.ruby, "-e", <<~'RUBY')
            gem "prometheus_exporter"
            require "prometheus_exporter"
            require "prometheus_exporter/client"
            require "prometheus_exporter/server"
            puts PrometheusExporter::VERSION
          RUBY
      assert_equal(PrometheusExporter::VERSION, stdout.strip)
    end
  end

  private

  def run!(environment, *command)
    stdout, stderr, status = Bundler.with_unbundled_env { Open3.capture3(environment, *command) }
    assert(status.success?, "#{command.join(" ")} failed:\n#{stdout}\n#{stderr}")
    stdout
  end
end
