# frozen_string_literal: true

# [unit] No consumer lock push before RubyGems serves the version.
#
# rel-20261110-208612: voicebox's CI went red on "version removed" because a lock bump
# reached GitHub seconds after the gem publish. The wait (await_published_gems!,
# GemServedWait) existed, but two lock-push paths (the producer bump and the cardless
# re-lock) did not call it. This guard reads bin/release.rb and holds the class: every
# function that runs `bundle_lock` and pushes calls the wait itself, or is reached only
# from one that does. History: task release-preflight-hardening.
require "minitest/autorun"

class ReleaseGemWaitGuardTest < Minitest::Test
  SOURCE = File.read(File.expand_path("../../bin/release.rb", __dir__))

  # Lock-push functions reached only through a caller that waits first.
  WAITED_BY_CALLER = { "repin_consumer!" => "repin_consumers",
                       "relock_cardless_consumer" => "relock_cardless_consumers" }.freeze

  def defs
    @defs ||= SOURCE.split(/^(?=def )/).filter_map do |body|
      name = body[/\Adef ([\w!?]+)/, 1]
      [name, body] if name
    end.to_h
  end

  def lock_pushers
    defs.select { |_name, body| body.include?("bundle_lock(") && body.include?('"push"') }
  end

  def test_the_guard_sees_the_lock_push_paths
    assert_operator lock_pushers.size, :>=, 4, "the scan must find the lock-push functions: #{lock_pushers.keys}"
  end

  def test_every_lock_push_waits_for_rubygems_first
    lock_pushers.each do |name, body|
      if (caller_name = WAITED_BY_CALLER[name])
        caller_body = defs.fetch(caller_name)
        assert_includes caller_body, "await_published_gems!", "#{caller_name} must wait before it calls #{name}"
        callers = defs.select { |other, text| other != name && text.include?("#{name}(") }.keys
        assert_equal [caller_name], callers, "#{name} must be reached only from #{caller_name}"
        next
      end

      await_at = body.index("await_published_gems!")
      refute_nil await_at, "#{name} pushes a lock bump but never calls await_published_gems!"
      assert_operator await_at, :<, body.index('"push"'), "#{name} must wait before its first push"
    end
  end

  def test_the_cardless_relock_waits_before_its_threads
    body = defs.fetch("relock_cardless_consumers")
    assert_operator body.index("await_published_gems!"), :<, body.index("Thread.new")
  end
end
