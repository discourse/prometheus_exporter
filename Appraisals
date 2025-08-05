# frozen_string_literal: true

appraise "ar-61" do
  gem "activerecord", "~> 6.1.1"

  # Fix:
  # warning: mutex_m was loaded from the standard library, but will no longer be part of the default gems since Ruby 3.4.0.
  # Add mutex_m to your Gemfile or gemspec.
  install_if '-> { Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.4.0") }' do
    gem 'mutex_m'
  end
end

appraise "ar-70" do
  gem "activerecord", "~> 7.0.0"

  # Fix:
  # warning: mutex_m was loaded from the standard library, but will no longer be part of the default gems since Ruby 3.4.0.
  # Add mutex_m to your Gemfile or gemspec.
  install_if '-> { Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.4.0") }' do
    gem 'mutex_m'
  end
end

appraise "ar-71" do
  gem "activerecord", "~> 7.1.0"
end

appraise "ar-80" do
  gem "activerecord", "~> 8.0.0"
end
