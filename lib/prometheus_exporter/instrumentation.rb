# frozen_string_literal: true

require_relative "client"
require_relative "instrumentation/process"
require_relative "instrumentation/method_profiler"
require_relative "instrumentation/sidekiq"
require_relative "instrumentation/delayed_job"
require_relative "instrumentation/puma"
require_relative "instrumentation/hutch"
require_relative "instrumentation/unicorn"
