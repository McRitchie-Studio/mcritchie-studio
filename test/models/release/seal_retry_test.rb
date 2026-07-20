require "test_helper"

class Release
  # Regression: rel-20260720-c06235 — the post-ship seal ran seconds after the
  # Actions deploy, landed inside the dyno boot/restart window, and recorded a
  # RED seal on a HEALTHY prod (re-run sealed 5/5 green minutes later). The fix
  # is ONE caller-side retry (Release::SealRetry) around the seal's smoke run:
  # first failure waits ~30s and retries once; only a PERSISTING failure seals
  # red; a first-attempt pass never sleeps. bin/prod-smoke itself stays an
  # honest single-shot tool.
  class SealRetryTest < ActiveSupport::TestCase
    # Records every sleep instead of sleeping, so the policy unit-tests without
    # a 30s wall-clock wait.
    def fake_sleeper(log) = ->(seconds) { log << seconds }

    test "[unit] a first-attempt pass never sleeps and never retries" do
      sleeps   = []
      attempts = []
      result = SealRetry.run(sleeper: fake_sleeper(sleeps)) do |attempt|
        attempts << attempt
        ["smoke out", true]
      end

      assert result.ok
      assert_not result.retried
      assert_equal 1, result.attempts
      assert_equal [1], attempts
      assert_empty sleeps, "a green first attempt must not sleep"
    end

    test "[unit] REGRESSION rel-20260720-c06235: a boot-window transient (first fails, retry passes) ends green with the retry flagged" do
      sleeps = []
      result = SealRetry.run(sleeper: fake_sleeper(sleeps)) do |attempt|
        attempt == 1 ? ["boot-window flake", false] : ["all green", true]
      end

      assert result.ok, "one transient failure must not red-seal a healthy prod"
      assert result.retried, "the green verdict must carry the retried flag for the seal summary"
      assert_equal 2, result.attempts
      assert_equal [SealRetry::DELAY_SECONDS], sleeps
      assert_equal "all green", result.out, "the FINAL attempt's output is the verdict's output"
    end

    test "[unit] a persisting failure still seals red after exactly ONE retry" do
      sleeps   = []
      attempts = []
      result = SealRetry.run(sleeper: fake_sleeper(sleeps)) do |attempt|
        attempts << attempt
        ["still down", false]
      end

      assert_not result.ok, "a real outage still seals red"
      assert result.retried
      assert_equal 2, result.attempts
      assert_equal [1, 2], attempts, "exactly one retry — never a loop"
      assert_equal 1, sleeps.size
    end

    test "[unit] the default boot-window delay is ~30s and is overridable" do
      assert_equal 30, SealRetry::DELAY_SECONDS

      sleeps = []
      SealRetry.run(delay: 5, sleeper: fake_sleeper(sleeps)) { |_attempt| ["", false] }
      assert_equal [5], sleeps
    end

    test "[unit] on_retry announces the wait BEFORE sleeping (ship-log ordering)" do
      order = []
      SealRetry.run(
        delay: 7,
        sleeper: ->(s) { order << [:sleep, s] },
        on_retry: ->(s) { order << [:announce, s] }
      ) { |attempt| ["", attempt == 2] }

      assert_equal [[:announce, 7], [:sleep, 7]], order
    end
  end
end
