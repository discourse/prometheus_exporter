# frozen_string_literal: true

require "simplecov"

# Start SimpleCov
SimpleCov.start { add_filter "test/" }

require "minitest/mock"
require "minitest/autorun"
require "openssl"
require "ostruct"
require "puma"
require "redis"

module TestingMod
  class FakeConnection
    def call_pipelined(...)
    end

    def call(...)
    end

    def connected?
      true
    end

    def revalidate
    end

    def retry_attempt=(v)
    end

    def read_timeout=(v)
    end

    def write_timeout=(v)
    end
  end

  def connect(_config)
    FakeConnection.new
  end
end

module RedisValidationMiddleware
  def self.reset!
    @@call_calls = 0
    @@call_pipelined_calls = 0
  end

  def self.call_calls
    @@call_calls || 0
  end

  def self.call_pipelined_calls
    @@call_pipelined_calls || 0
  end

  def call(command, _config)
    @@call_calls ||= 0
    @@call_calls += 1
    super
  end

  def call_pipelined(command, _config)
    @@call_pipelined_calls ||= 0
    @@call_pipelined_calls += 1
    super
  end
end

RedisClient::Middlewares.prepend(TestingMod)
RedisClient.register(RedisValidationMiddleware)

class TestHelper
  def self.wait_for(time, &blk)
    (time / 0.001).to_i.times do
      return true if blk.call
      sleep 0.001
    end
    false
  end
end

module ClockHelper
  def stub_monotonic_clock(at = 0.0, advance: nil, &blk)
    Process.stub(:clock_gettime, at + advance.to_f, Process::CLOCK_MONOTONIC, &blk)
  end
end

module CollectorHelper
  def setup
    PrometheusExporter::Metric::Base.default_prefix = ""
  end

  def max_metric_age
    @_max_age ||= get_max_metric_age
  end

  def collector_metric_lines
    collector.metrics.map(&:metric_text).join("\n").split("\n")
  end

  def assert_collector_metric_lines(expected)
    assert_equal(expected, collector_metric_lines)
  end

  private

  def get_max_metric_age
    klass = @collector.class
    unless klass.const_defined?(:MAX_METRIC_AGE)
      raise "Collector class #{@collector.class.name} must set MAX_METRIC_AGE constant!"
    end
    klass.const_get(:MAX_METRIC_AGE)
  end
end

# Generates a CA + server ("localhost") + client certificate/key chain on disk.
# Shared by the TLS tests in client_wire_test.rb and web_server_puma_test.rb.
module TlsTestChain
  def write_tls_chain(directory)
    ca_key = OpenSSL::PKey::RSA.new(2048)
    ca_cert = certificate("Prometheus Exporter Test CA", ca_key, serial: 1, ca: true)
    server_key = OpenSSL::PKey::RSA.new(2048)
    server_cert =
      certificate("localhost", server_key, serial: 2, issuer_cert: ca_cert, issuer_key: ca_key)
    client_key = OpenSSL::PKey::RSA.new(2048)
    client_cert =
      certificate("client", client_key, serial: 3, issuer_cert: ca_cert, issuer_key: ca_key)

    {
      ca_cert: ["ca.crt", ca_cert.to_pem],
      server_cert: ["server.crt", server_cert.to_pem],
      server_key: ["server.key", server_key.to_pem],
      client_cert: ["client.crt", client_cert.to_pem],
      client_key: ["client.key", client_key.to_pem],
    }.transform_values do |filename, contents|
      path = File.join(directory, filename)
      File.write(path, contents)
      path
    end
  end

  def certificate(common_name, key, serial:, ca: false, issuer_cert: nil, issuer_key: nil)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = serial
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{common_name}")
    cert.issuer = issuer_cert ? issuer_cert.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600

    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = cert
    extensions.issuer_certificate = issuer_cert || cert
    cert.add_extension(
      extensions.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true),
    )
    cert.add_extension(
      extensions.create_extension(
        "keyUsage",
        ca ? "keyCertSign,cRLSign" : "digitalSignature,keyEncipherment",
        true,
      ),
    )
    if !ca && common_name == "localhost"
      cert.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost"))
    end
    cert.sign(issuer_key || key, OpenSSL::Digest.new("SHA256"))
    cert
  end
end

module PumaVersionHelper
  def puma_reports_busy_threads?
    Gem::Version.new(Puma::Const::VERSION) >= Gem::Version.new("6.6.0")
  end
end

# Allow stubbing process monotonic clock from any class in the suite
Minitest::Test.send(:include, ClockHelper)
Minitest::Test.send(:include, PumaVersionHelper)

# Load our gem
require "prometheus_exporter"
