# frozen_string_literal: true

# see https://samsaffron.com/archive/2017/10/18/fastest-way-to-profile-a-method-in-ruby
module PrometheusExporter::Instrumentation; end

class PrometheusExporter::Instrumentation::MethodProfiler
  def self.patch(klass, methods, name, instrument:)
    if instrument == :alias_method
      patch_using_alias_method(klass, methods, name)
    elsif instrument == :prepend
      patch_using_prepend(klass, methods, name)
    else
      raise ArgumentError, "instrument must be :alias_method or :prepend"
    end
  end

  def self.transfer
    result = Thread.current[:_method_profiler]
    Thread.current[:_method_profiler] = nil
    result
  end

  def self.start(transfer = nil)
    Thread.current[:_method_profiler] = transfer || {
      __start: Process.clock_gettime(Process::CLOCK_MONOTONIC)
    }
  end

  def self.clear
    Thread.current[:_method_profiler] = nil
  end

  def self.stop
    finish = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if data = Thread.current[:_method_profiler]
      Thread.current[:_method_profiler] = nil
      start = data.delete(:__start)
      data[:total_duration] = finish - start
    end
    data
  end

  def self.define_methods_on_module(klass, methods, name)
    patch_source_line = __LINE__ + 3
    patches = methods.map do |method_name|
      <<~RUBY
        def #{method_name}(*args, &blk)
          unless prof = Thread.current[:_method_profiler]
            return super
          end
          begin
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            super
          ensure
            data = (prof[:#{name}] ||= {duration: 0.0, calls: 0})
            data[:duration] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
            data[:calls] += 1
          end
        end
      RUBY
    end.join("\n")

    klass.module_eval patches, __FILE__, patch_source_line
  end

  def self.patch_using_prepend(klass, methods, name)
    prepend_instrument = Module.new
    define_methods_on_module(prepend_instrument, methods, name)
    klass.prepend(prepend_instrument)
  end

  def self.patch_using_alias_method(klass, methods, name)
    patch_source_line = __LINE__ + 3
    patches = methods.map do |method_name|
      <<~RUBY
      unless defined?(#{method_name}__mp_unpatched)
        alias_method :#{method_name}__mp_unpatched, :#{method_name}
        def #{method_name}(*args, &blk)
          unless prof = Thread.current[:_method_profiler]
            return #{method_name}__mp_unpatched(*args, &blk)
          end
          begin
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            #{method_name}__mp_unpatched(*args, &blk)
          ensure
            data = (prof[:#{name}] ||= {duration: 0.0, calls: 0})
            data[:duration] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
            data[:calls] += 1
          end
        end
      end
      RUBY
    end.join("\n")

    klass.class_eval patches, __FILE__, patch_source_line
  end
end
