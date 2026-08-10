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
