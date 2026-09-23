# frozen_string_literal: true

# [unit] tests for bin/lib/artifact_sweep.rb — discovery, planning, byte math,
# and the rotation verdict. Pure logic against a tmpdir; no app is booted here.
# The end-to-end CLI (including the app-boot audit) is covered by
# test/lib/clean_artifacts_cli_test.rb.
# Run directly:
#   ruby -Itest test/lib/artifact_sweep_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/artifact_sweep"

class ArtifactSweepTest < Minitest::Test
  MB = 1024 * 1024

  # Build a fake projects root. `rails:` marks a repo as a Rails app by giving it
  # config/environments — the same marker discovery uses.
  def with_root
    Dir.mktmpdir("sweep-root") do |root|
      yield root
    end
  end

  def make_repo(root, name, rails: true, worktrees: [])
    repo = File.join(root, name)
    FileUtils.mkdir_p(File.join(repo, rails ? "config/environments" : "config"))
    FileUtils.mkdir_p(File.join(repo, "log"))
    worktrees.each { |wt| FileUtils.mkdir_p(File.join(repo, ".worktrees", wt, "log")) }
    repo
  end

  def write(path, bytes)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x" * bytes)
    path
  end

  # --- discovery ----------------------------------------------------------
  # THE FIRST DEFECT: the old script hardcoded RAILS_REPOS=(turf-monster
  # mcritchie-studio) — 2 of 9 — which is exactly how chain-ops/log/localnet.log
  # reached 388 MB completely unswept.

  def test_discovers_every_rails_repo_rather_than_a_hardcoded_list
    with_root do |root|
      %w[alpha beta gamma].each { |name| make_repo(root, name) }

      assert_equal %w[alpha beta gamma],
                   ArtifactSweep.rails_repos(root).map { |r| File.basename(r) }
    end
  end

  def test_a_brand_new_app_is_swept_the_day_it_lands
    with_root do |root|
      make_repo(root, "existing")
      before = ArtifactSweep.rails_repos(root).size
      make_repo(root, "brand-new-satellite")

      assert_equal before + 1, ArtifactSweep.rails_repos(root).size,
                   "discovery must pick a new app up with no edit to this script"
    end
  end

  def test_skips_non_rails_directories_and_dotfiles
    with_root do |root|
      make_repo(root, "app")
      make_repo(root, "a-gem", rails: false)
      FileUtils.mkdir_p(File.join(root, ".agents"))
      File.write(File.join(root, "AGENTS.md"), "x")

      assert_equal %w[app], ArtifactSweep.rails_repos(root).map { |r| File.basename(r) }
    end
  end

  # --- worktrees ----------------------------------------------------------
  # THE SECOND DEFECT: the old script swept only $repo/log, never
  # $repo/.worktrees/*/log — where most of the volume lived, because every desk
  # boots its own stack.

  def test_checkouts_include_every_worktree_under_the_repo
    with_root do |root|
      repo = make_repo(root, "app", worktrees: %w[desk-one desk-two])

      assert_equal ["app", "desk-one", "desk-two"],
                   ArtifactSweep.checkouts_for(repo).map { |c| File.basename(c) }
    end
  end

  def test_plan_counts_worktree_logs_not_just_the_primary
    with_root do |root|
      repo = make_repo(root, "app", worktrees: %w[desk])
      write(File.join(repo, "log", "development.log"), 1 * MB)
      write(File.join(repo, ".worktrees", "desk", "log", "development.log"), 3 * MB)

      plan = ArtifactSweep.plan(root)

      assert_equal 4 * MB, plan[:bytes], "the worktree's 3 MB must be in the plan"
      assert_equal 1, plan[:worktree_count]
    end
  end

  # --- what is and is not a target ----------------------------------------

  def test_targets_live_logs_rotated_logs_cache_and_coverage
    with_root do |root|
      repo = make_repo(root, "app")
      write(File.join(repo, "log", "development.log"), 100)
      write(File.join(repo, "log", "development.log.0"), 200)
      write(File.join(repo, "tmp", "cache", "bootsnap", "data"), 300)
      write(File.join(repo, "tmp", "brakeman.json"), 400)
      write(File.join(repo, "coverage", "index.html"), 500)

      targets = ArtifactSweep.targets_for(repo)

      assert_equal 1500, targets.sum(&:bytes)
      assert_equal :truncate, targets.find { |t| t.path.end_with?("development.log") }.kind,
                   "a LIVE log is truncated in place so a running server keeps its handle"
      assert_equal :delete, targets.find { |t| t.path.end_with?("development.log.0") }.kind
    end
  end

  def test_never_targets_pids_sockets_storage_db_or_env
    with_root do |root|
      repo = make_repo(root, "app")
      protected_paths = [
        write(File.join(repo, "tmp", "pids", "server.pid"), 10),
        write(File.join(repo, "tmp", "sockets", "puma.sock"), 10),
        write(File.join(repo, "tmp", "storage", "blob"), 10),
        write(File.join(repo, "db", "schema.rb"), 10),
        write(File.join(repo, "storage", "upload.png"), 10),
        write(File.join(repo, ".env"), 10)
      ]

      targeted = ArtifactSweep.targets_for(repo).map(&:path)
      protected_paths.each do |path|
        refute_includes targeted, path, "#{File.basename(path)} must never be swept"
      end
    end
  end

  # --- applying -----------------------------------------------------------

  def test_apply_truncates_live_logs_in_place_and_deletes_the_rest
    with_root do |root|
      repo = make_repo(root, "app")
      live = write(File.join(repo, "log", "development.log"), 2 * MB)
      rotated = write(File.join(repo, "log", "development.log.0"), 1 * MB)
      inode_before = File.stat(live).ino

      freed = ArtifactSweep.apply!(ArtifactSweep.targets_for(repo))

      assert_equal 3 * MB, freed
      assert File.exist?(live), "the live log must survive as an empty file"
      assert_equal 0, File.size(live)
      assert_equal inode_before, File.stat(live).ino,
                   "truncate must keep the inode — a running server holds this handle open"
      refute File.exist?(rotated)
    end
  end

  def test_apply_survives_a_target_that_vanished_between_plan_and_sweep
    with_root do |root|
      repo = make_repo(root, "app")
      write(File.join(repo, "log", "development.log"), 100)
      targets = ArtifactSweep.targets_for(repo)
      FileUtils.rm_rf(File.join(repo, "log"))

      assert_equal 0, ArtifactSweep.apply!(targets), "a vanished target frees nothing, and does not raise"
    end
  end

  # --- the rotation verdict ------------------------------------------------
  # The self-healing half. The subtle part: Rails rotates every LOCAL log by
  # default (config.load_defaults "7.1" → 100 MB), so a check that merely asks
  # "is it rotating?" answers yes forever and never reports anything. The
  # question has to be "is it bounded at a cap we would accept?"

  def test_a_sane_cap_is_ok
    assert_equal :ok, ArtifactSweep.rotation_verdict(cap: 16 * MB, shift_age: 1)
    assert_equal :ok, ArtifactSweep.rotation_verdict(cap: 8 * MB, shift_age: 1)
  end

  def test_rails_own_100mb_default_is_reported_not_congratulated
    assert_equal :loose, ArtifactSweep.rotation_verdict(cap: ArtifactSweep::RAILS_DEFAULT_CAP, shift_age: 1),
                 "an app on Rails' default has NOT adopted the engine cap and must be named"
  end

  def test_no_rotation_at_all_is_none
    assert_equal :none, ArtifactSweep.rotation_verdict(cap: nil, shift_age: 0)
    assert_equal :none, ArtifactSweep.rotation_verdict(cap: 5 * MB, shift_age: 0),
                 "a cap with shift_age 0 never rotates — the size is decoration"
    assert_equal :none, ArtifactSweep.rotation_verdict(cap: nil, shift_age: nil)
  end

  def test_the_healthy_threshold_sits_between_the_engine_cap_and_rails_default
    assert_operator ArtifactSweep::MAX_HEALTHY_CAP, :<, ArtifactSweep::RAILS_DEFAULT_CAP,
                    "if the threshold reached Rails' default, every app would read healthy forever"
    assert_operator ArtifactSweep::MAX_HEALTHY_CAP, :>, 16 * MB,
                    "the engine's 16 MB development cap must land comfortably inside healthy"
  end

  # --- coverage: is every managed app PROVEN capped? -----------------------
  # [unit] The filed test plan for cap-loose-app-logs: "the audit reports LOOSE
  # for an app with no cap" — and the half that plan is really about, which is
  # that an app the audit could NOT prove must not come back looking capped.
  #
  # The bug these lock down is an ABSENCE, so every case below asserts against
  # :capped rather than merely asserting the happy path. Three different
  # situations emit `rotation_missing: []`, and only ONE of them is a clean
  # machine; before this classifier the other two printed the same nothing.

  def test_an_audit_that_reached_every_app_and_found_them_capped_is_the_only_pass
    summary = { audited_envs: %w[development], rotation_missing: [], rotation_unknown: [] }

    assert_equal :capped, ArtifactSweep.rotation_coverage(summary)
    assert ArtifactSweep.rotation_proven?(summary)
    assert_equal ["✓ every audited app caps its local logs (development)"],
                 ArtifactSweep.rotation_report_lines(summary)
  end

  def test_a_loose_app_is_named_and_the_run_is_not_a_pass
    summary = { audited_envs: %w[development], rotation_missing: %w[rolio chain-ops], rotation_unknown: [] }

    assert_equal :uncapped, ArtifactSweep.rotation_coverage(summary)
    refute ArtifactSweep.rotation_proven?(summary)
    report = ArtifactSweep.rotation_report_lines(summary).join("\n")
    assert_includes report, "rolio", "the audit must NAME the loose app, not just count it"
    assert_includes report, "chain-ops"
    assert_includes report, ArtifactSweep::ENGINE_CAP_FLOOR,
                    "name the engine floor: three of the loose apps already carry studio-engine"
  end

  def test_an_app_that_could_not_be_booted_is_unproven_never_capped
    summary = { audited_envs: %w[development], rotation_missing: [], rotation_unknown: %w[karen_mcritchie] }

    assert_equal :unproven, ArtifactSweep.rotation_coverage(summary),
                 "an empty rotation_missing with an unbootable app is NOT a clean machine"
    refute ArtifactSweep.rotation_proven?(summary)
    report = ArtifactSweep.rotation_report_lines(summary).join("\n")
    assert_includes report, "karen_mcritchie"
    assert_includes report, "NOT PROVEN"
  end

  def test_a_loose_app_and_an_unprovable_one_are_both_named_in_the_same_run
    summary = { audited_envs: %w[development], rotation_missing: %w[rolio], rotation_unknown: %w[karen_mcritchie] }
    report = ArtifactSweep.rotation_report_lines(summary)

    assert_equal 2, report.size, "the worst verdict must not swallow the other category"
    assert_includes report.join("\n"), "rolio"
    assert_includes report.join("\n"), "karen_mcritchie"
  end

  def test_a_skipped_audit_does_not_read_as_a_capped_machine
    summary = { audited_envs: [], rotation_missing: [], rotation_unknown: [] }

    assert_equal :unaudited, ArtifactSweep.rotation_coverage(summary),
                 "--skip-audit emits the same empty lists a clean machine does"
    refute ArtifactSweep.rotation_proven?(summary)
    assert_includes ArtifactSweep.rotation_report_lines(summary).join("\n"), "did not run"
  end

  # bin/release archive's sweep_summary returns {} when the tagged line is absent,
  # on purpose — a sweep hiccup must not abort a run whose board work landed. That
  # degraded hash must still not read as proof.
  def test_a_summary_with_no_audit_fields_is_unreadable_not_clean
    assert_equal :unreadable, ArtifactSweep.rotation_coverage({})
    assert_equal :unreadable, ArtifactSweep.rotation_coverage(nil)
    refute ArtifactSweep.rotation_proven?({})
    assert_includes ArtifactSweep.rotation_report_lines({}).join("\n"), "NOT PROVEN"
  end

  def test_every_verdict_says_something
    ArtifactSweep::ROTATION_COVERAGE_VERDICTS.each do |verdict|
      summary =
        case verdict
        when :unreadable then {}
        when :unaudited  then { audited_envs: [] }
        when :uncapped   then { audited_envs: %w[development], rotation_missing: %w[a] }
        when :unproven   then { audited_envs: %w[development], rotation_unknown: %w[a] }
        when :capped     then { audited_envs: %w[development] }
        end

      assert_equal verdict, ArtifactSweep.rotation_coverage(summary), verdict.to_s
      refute_empty ArtifactSweep.rotation_report_lines(summary),
                   "#{verdict} returned no line — silence is the defect this replaced"
    end
  end

  # --- the remedy is split by population ------------------------------------
  #
  # One sentence cannot be true of both populations. The report said "these apps
  # have not adopted the studio-engine cap (needs >= 0.33.0)" to a combined list,
  # which is accurate for an app pinned BELOW the floor and actively misleading
  # for one with no studio-engine dependency at all: it reads as "bump the pin"
  # to an owner who has no pin to bump. Measured 2026-09-22: chain-ops and rolio
  # carry zero studio-engine references in Gemfile AND Gemfile.lock.

  def test_an_app_with_no_engine_dependency_is_never_told_to_bump_a_pin
    summary = { audited_envs: %w[development], rotation_missing: %w[chain-ops rolio],
                engine_pins: { "chain-ops" => ArtifactSweep::ENGINE_PIN_ABSENT,
                               "rolio" => ArtifactSweep::ENGINE_PIN_ABSENT } }

    report = ArtifactSweep.rotation_report_lines(summary).join("\n")

    assert_includes report, "chain-ops"
    assert_includes report, "rolio"
    assert_includes report, "NO PIN TO BUMP",
                    "an app with no studio-engine dependency was handed the stale-pin remedy — it will " \
                    "be read as 'bump the pin', and there is no pin in that repo to bump"
    refute_match(/Bump the pin and relock/, report,
                 "the bump remedy reached a population that has nothing to bump")
    assert_includes report, ArtifactSweep::ENGINE_CAP_FLOOR,
                    "the floor still has to appear: it is the version the new dependency must satisfy"
  end

  def test_an_app_pinned_below_the_floor_is_told_to_bump_and_its_version_is_named
    summary = { audited_envs: %w[development], rotation_missing: %w[moms-app],
                engine_pins: { "moms-app" => "0.32.1" } }

    report = ArtifactSweep.rotation_report_lines(summary).join("\n")

    assert_includes report, "0.32.1", "name the version the app actually resolves, not just the floor"
    assert_includes report, "Bump the pin and relock"
    refute_includes report, "NO PIN TO BUMP"
  end

  # Both populations in one run must produce BOTH remedies — the split is
  # worthless if one swallows the other.
  def test_the_two_populations_are_reported_apart_in_the_same_run
    summary = { audited_envs: %w[development], rotation_missing: %w[chain-ops moms-app],
                engine_pins: { "chain-ops" => ArtifactSweep::ENGINE_PIN_ABSENT, "moms-app" => "0.32.1" } }

    report = ArtifactSweep.rotation_report_lines(summary)

    assert_equal 2, report.size, "two populations, two remedies"
    assert(report.any? { |line| line.include?("NO PIN TO BUMP") && line.include?("chain-ops") })
    assert(report.any? { |line| line.include?("Bump the pin") && line.include?("moms-app") })
  end

  # An app already carrying the floor and STILL loose is a third diagnosis: the
  # pin is fine and the initializer did not run early enough. Telling that owner
  # to bump a pin sends them at the one thing that is already correct.
  def test_an_app_at_the_floor_that_is_still_loose_is_not_told_to_bump
    summary = { audited_envs: %w[development], rotation_missing: %w[some-app],
                engine_pins: { "some-app" => "0.76.2" } }

    report = ArtifactSweep.rotation_report_lines(summary).join("\n")

    assert_includes report, "BOOTSTRAP initializer"
    refute_includes report, "Bump the pin and relock"
  end

  # A summary from before this field existed, or a repo whose lock could not be
  # read, must still get a line — and must not have a remedy GUESSED for it.
  def test_an_unclassified_population_degrades_to_the_shared_claim
    summary = { audited_envs: %w[development], rotation_missing: %w[rolio chain-ops] }

    report = ArtifactSweep.rotation_report_lines(summary).join("\n")

    assert_includes report, "rolio"
    assert_includes report, ArtifactSweep::ENGINE_CAP_FLOOR
    refute_includes report, "NO PIN TO BUMP", "no classification reached us; a remedy must not be invented"
    refute_includes report, "Bump the pin and relock"
  end

  # THE JSON ROUND TRIP. bin/release archive reads this summary back through
  # parse_summary, which symbolizes keys — so the per-app hashes arrive keyed by
  # SYMBOL while the in-process ones are keyed by String. A lookup written for
  # one shape silently finds nothing in the other and every app reads
  # unclassified, which looks exactly like a machine with no data.
  def test_the_report_survives_the_summary_round_trip_the_archive_lane_uses
    summary = { audited_envs: %w[development], rotation_missing: %w[chain-ops moms-app],
                rotation_unknown: %w[karen_mcritchie],
                rotation_unknown_reasons: { "karen_mcritchie" => "Could not find rails-4.1.6" },
                engine_pins: { "chain-ops" => ArtifactSweep::ENGINE_PIN_ABSENT, "moms-app" => "0.32.1" } }

    round_tripped = ArtifactSweep.parse_summary(ArtifactSweep.summary_line(summary))
    report = ArtifactSweep.rotation_report_lines(round_tripped).join("\n")

    assert_includes report, "NO PIN TO BUMP", "the pin classification did not survive symbolized keys"
    assert_includes report, "0.32.1"
    assert_includes report, "Could not find rails-4.1.6", "the unknown's reason did not survive the round trip"
  end

  # --- every unknown carries its reason --------------------------------------

  def test_each_unprovable_app_is_reported_with_the_reason_it_could_not_boot
    summary = { audited_envs: %w[development], rotation_unknown: %w[karen_mcritchie mcritchie-studio],
                rotation_unknown_reasons: { "karen_mcritchie" => "Could not find rails-4.1.6",
                                            "mcritchie-studio" => "Could not find studio-engine-0.76.2" } }

    report = ArtifactSweep.rotation_report_lines(summary)

    assert_equal 2, report.size, "one line per unknown, so a long reason cannot crowd out another app"
    assert(report.any? { |l| l.include?("karen_mcritchie") && l.include?("Could not find rails-4.1.6") })
    assert(report.any? { |l| l.include?("mcritchie-studio") && l.include?("studio-engine-0.76.2") })
    assert(report.all? { |l| l.include?("Never read UNKNOWN as a pass") })
  end

  def test_an_unknown_with_no_recorded_reason_says_so_rather_than_trailing_off
    summary = { audited_envs: %w[development], rotation_unknown: %w[mystery-app] }

    report = ArtifactSweep.rotation_report_lines(summary).join("\n")

    assert_includes report, "mystery-app"
    assert_includes report, "no reason was recorded",
                    "a missing reason must be stated; an empty clause reads as a truncated message"
  end

  # --- reading the engine pin off a checkout ---------------------------------

  def test_engine_pin_reads_the_resolved_version_from_the_lock
    Dir.mktmpdir("pin") do |repo|
      File.write(File.join(repo, "Gemfile.lock"), <<~LOCK)
        GEM
          specs:
            rails (8.1.3.1)
            studio-engine (0.32.1)
      LOCK

      assert_equal "0.32.1", ArtifactSweep.engine_pin(repo),
                   "the LOCK is the fact that boots — a `~> 0.31` requirement and a locked 0.32.1 " \
                   "are different numbers and only one of them runs"
    end
  end

  def test_engine_pin_distinguishes_no_dependency_from_unreadable
    Dir.mktmpdir("pin") do |repo|
      File.write(File.join(repo, "Gemfile.lock"), "GEM\n  specs:\n    rails (8.1.3.1)\n")

      assert_equal ArtifactSweep::ENGINE_PIN_ABSENT, ArtifactSweep.engine_pin(repo),
                   "a lock without studio-engine is a POSITIVE fact — the app has no pin — not a gap"
    end

    Dir.mktmpdir("pin") do |repo|
      assert_nil ArtifactSweep.engine_pin(repo), "no lock at all is unknown, and must not read as 'absent'"
    end
    assert_nil ArtifactSweep.engine_pin(nil)
  end

  def test_a_malformed_pin_is_unclassified_rather_than_raising
    assert_equal :unclassified, ArtifactSweep.engine_population("not-a-version"),
                 "a lock this parser cannot grade must degrade, never abort the closing report"
  end

  # --- parsing -------------------------------------------------------------

  def test_parses_the_audit_payload_out_of_chatty_boot_output
    output = <<~OUT
      DEPRECATION WARNING: something
      STUDIO_LOG_AUDIT {"cap":16777216,"shift_age":1,"path":"/app/log/development.log"}
    OUT

    assert_equal 16_777_216, ArtifactSweep.parse_audit_output(output)[:cap]
  end

  def test_audit_parse_returns_nil_rather_than_guessing
    assert_nil ArtifactSweep.parse_audit_output("boot failed\n")
    assert_nil ArtifactSweep.parse_audit_output("STUDIO_LOG_AUDIT not-json\n")
  end

  def test_summary_line_round_trips
    line = ArtifactSweep.summary_line(reclaimed_bytes: 42, rotation_missing: %w[chain-ops])
    parsed = ArtifactSweep.parse_summary("noise\n#{line}\nmore noise\n")

    assert_equal 42, parsed[:reclaimed_bytes]
    assert_equal %w[chain-ops], parsed[:rotation_missing]
  end

  def test_human_bytes_reads_at_a_glance
    assert_equal "0 B", ArtifactSweep.human_bytes(0)
    assert_equal "1.0 KB", ArtifactSweep.human_bytes(1024)
    assert_equal "388.0 MB", ArtifactSweep.human_bytes(388 * MB)
    assert_equal "1.2 GB", ArtifactSweep.human_bytes((1.2 * 1024 * MB).to_i)
  end
end
