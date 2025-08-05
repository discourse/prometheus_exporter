# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Dev libs
gem "appraisal", git: "https://github.com/thoughtbot/appraisal.git"
gem "activerecord", "~> 7.1"
gem "bundler", ">= 2.1.4"
gem "m"
gem "mini_racer", "~> 0.12.0"
gem "minitest", "~> 5.23.0"
gem "minitest-stub-const", "~> 0.6"
gem "oj", "~> 3.0"
gem "rack-test", "~> 2.1.0"
gem "rake", "~> 13.0"
gem "redis", "> 5"
gem "syntax_tree"
gem "syntax_tree-disable_ternary"
gem "raindrops", "~> 0.19" if !RUBY_ENGINE == "jruby"

# Dev tools / linter
gem "guard", "~> 2.0", require: false
gem "guard-minitest", "~> 2.0", require: false
gem "rubocop", ">= 0.69", require: false
gem "rubocop-discourse", ">= 3", require: false
