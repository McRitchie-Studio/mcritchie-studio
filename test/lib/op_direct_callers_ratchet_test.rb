# frozen_string_literal: true

# [unit] THE 1PASSWORD READS RATCHET: config/op_direct_callers.yml may only go down.
# `callers`: every file that runs `op` itself (bin/lib/op_call_scan.rb); a new one fails,
# a stale one fails. `daily_cap`: may not rise against origin/release (read from outside
# the diff, like rails_skip_ceiling_ratchet_test.rb). Runs no `op`; every row is synthetic.
# History: task agent-op-reads-ratchet.

require "minitest/autorun"
require "tmpdir"
require "open3"
require "fileutils"
require_relative "../../bin/lib/op_call_scan"
require_relative "../../bin/lib/op_reads_ratchet"

class OpDirectCallersRatchetTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CONFIG_REL = "config/op_direct_callers.yml"
  BASELINE_REF = "origin/release"
  # The cap this ratchet started at. It bounds the one case with no baseline file
  # (the PR that adds the config), so even that case cannot start higher.
  FIRST_CAP = 450

  def cfg
    @cfg ||= OpReadsRatchet.config("MCR_OP_RATCHET_CONFIG" => File.join(ROOT, CONFIG_REL))
  end

  # [new callers, stale entries] for a tree and an allowlist.
  def drift(root, allowed)
    found = OpCallScan.direct_callers(root)
    [found - allowed, allowed - found]
  end

  # ── the callers ────────────────────────────────────────────────────────────

  def test_unit_every_direct_op_caller_is_on_the_allowlist
    added, = drift(ROOT, cfg["callers"].keys)

    assert_empty added, "these files run 1Password's `op` themselves and are not in #{CONFIG_REL}. " \
                        "Read the credential through a purpose-built client instead (bin/secret, " \
                        "bin/gh-token, SoulSecrets, HerokuToken; docs/agents/modules/credential-access.md). " \
                        "If it truly must call op, add it to `callers` with a `client` and a `why`, " \
                        "where a reviewer will see it:\n  #{added.join("\n  ")}"
  end

  def test_unit_every_allowlisted_caller_still_runs_op
    _, stale = drift(ROOT, cfg["callers"].keys)

    assert_empty stale, "these #{CONFIG_REL} callers no longer run `op` (or no longer exist). " \
                        "Drop them: the list only shrinks.\n  #{stale.join("\n  ")}"
  end

  # The test_plan control: a script outside the allowlist that calls op directly
  # FAILS, metered or raw; a script that asks bin/secret does not.
  def test_unit_the_ratchet_fails_when_a_script_outside_the_allowlist_calls_op_directly
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin", "lib"))
      File.write(File.join(dir, "bin", "lib", "listed.rb"), %(OpMeter.popen({}, ["op", "read", ref], via: "x")\n))
      File.write(File.join(dir, "bin", "lib", "metered.rb"), %(OpMeter.popen({}, ["op", "read", ref], via: "y")\n))
      File.write(File.join(dir, "bin", "raw"), %(#!/bin/bash\nvalue="$(op read "$ref")"\n))
      File.write(File.join(dir, "bin", "lib", "client.rb"), %(value = `bin/secret studio-agents x credential`\n))
      File.write(File.join(dir, "bin", "lib", "prose.rb"), %(# run `op read op://v/i/f` by hand\nwarn "check `op vault list`"\n))

      added, stale = drift(dir, %w[bin/lib/listed.rb bin/lib/gone.rb])

      assert_equal %w[bin/lib/metered.rb bin/raw], added, "a new metered caller and a new raw caller both fail"
      assert_equal %w[bin/lib/gone.rb], stale, "an entry that runs no op any more fails as stale"
    end
  end

  # ── the cap ────────────────────────────────────────────────────────────────

  def git(*args)
    out, status = Open3.capture2("git", "-C", ROOT, *args, err: File::NULL)
    status.success? ? out : nil
  end

  # [cap, where] or [nil, why]. The config missing from the baseline (only the PR
  # that adds it) answers FIRST_CAP.
  def baseline_cap
    return [nil, "git cannot read #{ROOT}"] unless git("rev-parse", "--git-dir")
    unless git("rev-parse", "--verify", "--quiet", "#{BASELINE_REF}^{commit}")
      return [nil, "`#{BASELINE_REF}` does not resolve; run `git fetch origin release` (CI: fetch-depth 0)"]
    end

    released = git("show", "#{BASELINE_REF}:#{CONFIG_REL}")
    return [FIRST_CAP, "FIRST_CAP (#{CONFIG_REL} is not on #{BASELINE_REF} yet)"] unless released

    [OpReadsRatchet.validate!(YAML.safe_load(released, permitted_classes: [Date], aliases: false))["daily_cap"],
     "#{BASELINE_REF}:#{CONFIG_REL}"]
  rescue OpReadsRatchet::ConfigError => e
    [nil, "#{BASELINE_REF}:#{CONFIG_REL} does not validate (#{e.message})"]
  end

  def test_unit_the_daily_cap_may_fall_but_never_rise
    baseline, where = baseline_cap

    refute_nil baseline, "the ratchet cannot see its baseline (#{where}), so it cannot certify the cap did not rise"
    assert_operator cfg["daily_cap"], :<=, baseline,
                    "#{CONFIG_REL} raises daily_cap from #{baseline} (#{where}) to #{cfg['daily_cap']}. " \
                    "The cap only goes down: move the caller that grew behind a cached client instead."
  end

  def test_unit_the_config_refuses_a_rising_history_and_a_cap_off_the_history
    base = { "daily_cap" => 400, "callers" => {},
             "cap_history" => [{ "cap" => 450 }, { "cap" => 400 }] }
    assert OpReadsRatchet.validate!(base)

    rising = base.merge("cap_history" => [{ "cap" => 400 }, { "cap" => 450 }], "daily_cap" => 450)
    assert_raises(OpReadsRatchet::ConfigError) { OpReadsRatchet.validate!(rising) }

    off = base.merge("daily_cap" => 300)
    assert_raises(OpReadsRatchet::ConfigError) { OpReadsRatchet.validate!(off) }

    nameless = base.merge("callers" => { "bin/x" => { "client" => "self" } })
    assert_raises(OpReadsRatchet::ConfigError) { OpReadsRatchet.validate!(nameless) }
  end

  # ── what counts ────────────────────────────────────────────────────────────

  def row(ts, caller, action: "read", outcome: "ok", via: "v")
    { "ts" => ts, "caller" => caller, "action" => action, "outcome" => outcome, "via" => via }
  end

  def test_unit_only_op_calls_inside_the_rolling_day_count
    now = Time.utc(2026, 11, 9, 12, 0, 0)
    rows = [
      row("2026-11-09T11:00:00Z", "gh-token", via: "gh-token:deployer"),
      row("2026-11-09T10:00:00Z", "gh-token", via: "gh-token:agent"),
      row("2026-11-09T09:00:00Z", "secret", outcome: "fail:1"),                # answered: counts
      row("2026-11-09T09:00:00Z", "release.rb", outcome: "timeout"),          # never reached the server
      row("2026-11-09T09:00:00Z", "secret", outcome: "fail:127"),             # op absent
      row("2026-11-09T09:00:00Z", "release.rb", action: "cache-hit"),         # bookkeeping
      row("2026-11-09T09:00:00Z", "submit", action: "auth-refresh"),          # bookkeeping
      row("2026-11-09T09:00:00Z", "secret", action: "soul-refused", outcome: "refused"),
      row("2026-11-08T11:59:59Z", "gh-token")                                 # outside the day
    ]
    rep = OpReadsRatchet.report(rows, { "daily_cap" => 2 }, now: now)

    assert_equal 3, rep["count"]
    assert rep["over"], "3 calls against a cap of 2 is over"
    assert_equal [%w[gh-token 2], %w[secret 1]], rep["callers"].map { |c| [c["caller"], c["reads"].to_s] }
    assert_includes rep["callers"].first["via"], "gh-token:deployer×1"
    refute OpReadsRatchet.report(rows, { "daily_cap" => 3 }, now: now)["over"], "at the cap is not over"
  end
end
