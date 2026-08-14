# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/package_load_test.rb")
end

Rake::TestTask.new(:package_smoke) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/package_load_test.rb"]
end

task default: :test
