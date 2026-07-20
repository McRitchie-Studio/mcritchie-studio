# frozen_string_literal: true

require "test_helper"
require "open3"

# The seal's boot-window retry, exercised END-TO-END (rel-20260720-c06235).
#
# REVIEW ROUND 2 (carl, request-changes): "static-only integration coverage".
# Round 1 asserted the wiring by GREPPING bin/release.rb's source — a test that
# passes on text, not behavior. This lane now RUNS the real composition
# (Release::SealRun → SealRetry + SmokeSeal) and asserts the OBSERVABLE seal a
# ship would record: green-after-retry, red-on-persistent, never-sleep-on-pass.
# A source tripwire survives only as a supplement (last test), never the proof.
class SealRetryWiringTest < ActionDispatch::IntegrationTest
  RELEASE_SRC = Rails.root.join("bin", "release.rb")
  SMOKE_SRC   = Rails.root.join("bin", "prod-smoke")

  # A scripted smoke: each call returns the next [out, ok] pair, and every
  # attempt is recorded — the stand-in for `run_test_scope("prod_smoke_seal"…)`.
  def scripted_smoke(*results)
    calls = []
    runner = lambda do |attempt|
      calls << attempt
      results[calls.size - 1]
    end
    [runner, calls]
  end

  def seal_run(smoke, sleeps: [])
    Release::SealRun.call(
      host: "https://mcritchie.studio",
      sleeper: ->(s) { sleeps << s },
      &smoke
    )
  end

  test "[integration] REGRESSION: a boot-window transient seals GREEN, and the summary says it retried" do
    smoke, calls = scripted_smoke(["GET /tasks non-OK", false], ["5 examples, 0 failures", true])
    sleeps = []
    result = seal_run(smoke, sleeps: sleeps)

    assert result.seal.green?, "a healthy prod caught mid-boot must NOT record a red seal"
    assert_equal "🟢", result.seal.badge
    assert_equal [1, 2], calls, "the smoke ran twice — one retry"
    assert_equal [Release::SealRetry::DELAY_SECONDS], sleeps
    assert_match(/retried once after 30s boot-window wait/, result.seal.summary,
      "the green verdict stays honest: the board/notes show it took a retry")
    assert_empty result.seal.rollback_commands, "no rollback guidance on a green seal"
  end

  test "[integration] a persisting failure seals RED with the exact rollback guidance" do
    smoke, calls = scripted_smoke(["down", false], ["still down", false])
    result = seal_run(smoke)

    assert result.seal.red?, "a real outage still seals red"
    assert_equal [1, 2], calls, "exactly one retry, then the verdict stands"
    assert_match(/FAILED/, result.seal.summary)
    assert_match(/retried once after 30s boot-window wait/, result.seal.summary,
      "a red seal proves it was NOT a boot-window blip — the retry is on the record")
    cmds = result.seal.rollback_commands(repo: "mcritchie-studio", heroku_app: "mcritchie-studio", deployed_sha: "abc1234")
    assert_includes cmds[0], "heroku rollback --app mcritchie-studio"
  end

  test "[integration] a first-attempt pass seals GREEN immediately — one run, no sleep, no retry note" do
    smoke, calls = scripted_smoke(["5 examples, 0 failures", true])
    sleeps = []
    result = seal_run(smoke, sleeps: sleeps)

    assert result.seal.green?
    assert_equal [1], calls, "the happy path never re-runs the suite"
    assert_empty sleeps, "the happy path never delays the ship"
    assert_no_match(/retried/, result.seal.summary)
  end

  test "[integration] the FINAL attempt's output is what the ship log and verdict carry" do
    smoke, = scripted_smoke(["first attempt noise", false], ["final attempt output", true])
    result = seal_run(smoke)

    assert_equal "final attempt output", result.out
    assert result.retried
  end

  test "[integration] the seal composition loads and runs RAILS-FREE, exactly as bin/release requires it" do
    # bin/release.rb is a plain Ruby script — it require_relative's these models
    # with NO Rails boot. Proven by EXECUTION in a bare ruby subprocess (a
    # missing/Rails-dependent constant would abort the ship at step 5c).
    script = <<~RUBY
      require_relative "#{Rails.root.join('app/models/release/smoke_seal')}"
      require_relative "#{Rails.root.join('app/models/release/seal_retry')}"
      require_relative "#{Rails.root.join('app/models/release/seal_run')}"
      attempts = 0
      r = Release::SealRun.call(host: "https://example.test", sleeper: ->(_s) {}) do |_a|
        attempts += 1
        ["out", attempts == 2]
      end
      puts [r.seal.status, attempts, r.retried].join(",")
    RUBY
    out, status = Open3.capture2(SessionEnv.neutralized, "ruby", "-e", script)

    assert status.success?, "the seal models must load standalone without Rails: #{out}"
    assert_equal "green,2,true", out.strip
  end

  test "[integration] bin/release step 5c wires the seal through SealRun, and bin/prod-smoke stays single-shot" do
    # Supplementary tripwire ONLY — the behavior above is the proof. This guards
    # the one seam a unit test cannot see: that the SCRIPT actually calls the
    # composition, and that the retry never leaked into the standalone tool.
    body = File.read(RELEASE_SRC)[/^def production_smoke_seal.*?(?=^def )/m]
    assert body, "bin/release.rb defines production_smoke_seal (step 5c)"
    assert_includes body, "Release::SealRun.call", "step 5c runs the smoke through the retrying composition"

    smoke = File.read(SMOKE_SRC)
    assert_no_match(/SealRetry|SealRun/, smoke, "the retry is caller-side; the tool stays single-shot")
    assert_no_match(/\bsleep\b/, smoke, "bin/prod-smoke never sleeps — it reports one honest verdict")
  end
end
