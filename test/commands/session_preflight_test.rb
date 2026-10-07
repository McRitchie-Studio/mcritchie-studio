# frozen_string_literal: true

# Standalone coverage for bin/session-preflight. The command is intentionally
# tested through its CLI seams so it can be used before Rails or the live task
# board are available.

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require_relative "../support/session_env"

class SessionPreflightTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "session-preflight")

  def setup
    @sandbox = Dir.mktmpdir("session-preflight")
    @repo = File.join(@sandbox, "repo")
    FileUtils.mkdir_p(@repo)
    write_feature_shapes
    write_installer(status: 0)
    git("init", "-q")
    git("config", "user.email", "tester@example.com")
    git("config", "user.name", "Tester")
    git("add", "-A")
    git("commit", "-q", "-m", "base")
    git("update-ref", "refs/remotes/origin/release", head)
    git("checkout", "-q", "-b", "feat/session-preflight")
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  def test_json_preflight_reports_feedback_shape_and_clean_docs
    task = write_task(
      latest_activity: {
        "activity_type" => "qa_feedback",
        "created_at" => "2026-06-26T12:00:00Z",
        "description" => "Reviewer note: check branch freshness first."
      }
    )

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal true, report.fetch("ok")
    assert_equal "Reviewer note: check branch freshness first.", report.fetch("latest_feedback").fetch("description")
    assert_equal %w[unit integration], report.fetch("shape").fetch("dor_tiers")
    assert_equal "pass", report.fetch("installed_docs").fetch("status")
  end

  # [unit] Row 3.8: a task the preflight cannot read is exit 2, so begin refuses
  # the claim on it.
  def test_an_unreadable_task_is_exit_two
    path = File.join(@sandbox, "broken.json")
    File.write(path, "not json")

    _out, err, status = run_preflight("--file", path, "--no-gh", "--no-install-docs", "--no-fetch", "--json")

    assert_equal 2, status.exitstatus, err
    assert_includes err, "could not parse task JSON"
  end

  # [unit] Guard catalog row 4.2: a blocked task is not a preflight failure; begin
  # clears the block at the claim and the preflight prints the feedback it carried.
  def test_a_blocked_task_passes_the_preflight
    path = File.join(@sandbox, "blocked.json")
    payload = task_payload.merge("blocked_at" => "2026-10-07T08:00:00Z", "block_kind" => "rework")
    File.write(path, JSON.generate("data" => payload))

    out, err, status = run_preflight("--file", path, "--no-gh", "--no-install-docs", "--no-fetch", "--json")

    assert status.success?, "a blocked task must not fail the preflight:\n#{out}\n#{err}"
    refute JSON.parse(out).fetch("errors").any? { |error| error.include?("blocked") }
  end

  # [unit] Guard catalog row 4.5: a branch behind its base is reported, never a
  # blocker. No gate needs a rebase and CI tests the merge ref.
  def test_branch_behind_release_is_reported_not_a_blocker
    task = write_task
    git("checkout", "-q", "--detach", "origin/release")
    release_commit = commit_file("docs/release.md", "release\n", "release moves")
    git("update-ref", "refs/remotes/origin/release", release_commit)
    git("checkout", "-q", "feat/session-preflight")

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal 1, report.fetch("branch").fetch("behind"), "FLOOR: the drift must have been measured"
    refute report.fetch("errors").any? { |error| error.include?("behind") }, report.fetch("errors").inspect
  end

  # [unit] The base ladder is accepted → release → main, mirroring
  # base_ref_for in bin/agent-worktree. A desk cut from origin/accepted must be
  # measured against origin/accepted — the release-first resolution used to
  # report false "behind origin/release" blockers on every accepted-based desk.
  def test_base_prefers_origin_accepted_over_release
    task = write_task
    git("update-ref", "refs/remotes/origin/accepted", head)

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal "origin/accepted", report.fetch("branch").fetch("base")
    assert_equal 0, report.fetch("branch").fetch("behind")
  end

  def test_behind_accepted_report_names_the_compared_ref
    task = write_task
    git("update-ref", "refs/remotes/origin/accepted", head)
    git("checkout", "-q", "--detach", "origin/accepted")
    accepted_commit = commit_file("docs/accepted.md", "accepted\n", "accepted moves")
    git("update-ref", "refs/remotes/origin/accepted", accepted_commit)
    git("checkout", "-q", "feat/session-preflight")

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?

    report = JSON.parse(out)
    assert_equal "origin/accepted", report.fetch("branch").fetch("base")
    assert_equal 1, report.fetch("branch").fetch("behind")
    human, = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch")
    assert_includes human, "vs origin/accepted"
    assert_includes human, "ahead 0, behind 1"
  end

  # [unit] SELF-DEFENSE for begin-preflight-wrong-root: a preflight is only
  # meaningful against the task's OWN checkout. When the inspected root is on a
  # different branch than the task (the classic failure: the report describes the
  # PRIMARY, not the task worktree), every drift/PR/overlap number is about the
  # wrong tree, so the command must REFUSE and say so — never silently report.
  # Asserted with an UNRELATED branch (not "main", not a ladder rung) so the guard
  # is the positive property "the inspected checkout holds the task's branch", not
  # a blacklist of known-wrong branch names.
  def test_wrong_checkout_root_is_refused
    task = write_task # devops.branch = feat/session-preflight
    git("update-ref", "refs/remotes/origin/accepted", head)
    git("checkout", "-q", "-b", "feat/some-other-desk") # a DIFFERENT branch than the task's
    # The wrong branch sits BEHIND accepted, so the report carries a drift number for
    # a tree that is not this task's; the refusal is what makes it meaningless.
    git("checkout", "-q", "--detach", "origin/accepted")
    accepted_commit = commit_file("docs/accepted.md", "moved\n", "accepted moves ahead")
    git("update-ref", "refs/remotes/origin/accepted", accepted_commit)
    git("checkout", "-q", "feat/some-other-desk")

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    refute status.success?, "a root on the wrong branch must be refused"
    assert_equal 2, status.exitstatus, "the wrong checkout is exit 2: begin refuses the claim on it (row 3.8)"

    report = JSON.parse(out)
    assert_equal 1, report.fetch("branch").fetch("behind")
    assert report.fetch("errors").any? { |error| error.downcase.include?("wrong checkout") },
           "must name the wrong-checkout blocker, got: #{report.fetch("errors").inspect}"
  end

  # [unit] The self-defense must NOT fire when the inspected checkout IS the task's
  # desk — the same-branch case that every green preflight relies on.
  def test_matching_checkout_root_passes_self_defense
    task = write_task # devops.branch = feat/session-preflight; repo is on feat/session-preflight
    git("update-ref", "refs/remotes/origin/accepted", head)

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"
    report = JSON.parse(out)
    refute report.fetch("errors").any? { |error| error.downcase.include?("wrong checkout") },
           report.fetch("errors").inspect
  end

  def test_base_falls_back_to_release_when_accepted_absent
    task = write_task

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal "origin/release", report.fetch("branch").fetch("base")
  end

  def test_base_falls_back_to_main_when_accepted_and_release_absent
    task = write_task
    git("update-ref", "-d", "refs/remotes/origin/release")
    git("update-ref", "refs/remotes/origin/main", head)

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal "origin/main", report.fetch("branch").fetch("base")
  end

  def test_missing_ladder_refs_warn_with_all_three_names
    task = write_task
    git("update-ref", "-d", "refs/remotes/origin/release")

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_nil report.fetch("branch").fetch("base")
    assert_includes report.fetch("branch").fetch("warning"), "origin/accepted"
    assert_includes report.fetch("branch").fetch("warning"), "origin/main"
  end

  # [unit] Fetching the ladder must tolerate missing rungs: a remote with only
  # `main` (no accepted/release yet) is a valid pre-cutover repo, not a fetch
  # failure worth warning about. The old fetch pulled ONLY `release`, so it
  # never refreshed accepted and warned on release-less repos.
  def test_fetch_tolerates_missing_ladder_rungs
    task = write_task
    bare = File.join(@sandbox, "origin.git")
    git("init", "-q", "--bare", bare)
    git("remote", "add", "origin", bare)
    git("push", "-q", "origin", "HEAD:refs/heads/main")
    git("update-ref", "-d", "refs/remotes/origin/release")
    git("update-ref", "-d", "refs/remotes/origin/main")

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_empty report.fetch("warnings").grep(/git fetch/), report.fetch("warnings").inspect
    assert_equal "origin/main", report.fetch("branch").fetch("base")
  end

  def test_stale_terminology_scan_blocks_active_docs
    task = write_task
    write_file("docs/agents/modules/stale.md", "Use GET /api/v1/tasks?stage=queued here.\n")

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    refute status.success?
    assert_equal 1, status.exitstatus, "a finding is exit 1: begin reports it and claims (row 3.8)"

    report = JSON.parse(out)
    hit = report.fetch("stale_terms").first
    assert_equal "docs/agents/modules/stale.md", hit.fetch("file")
    assert_equal "legacy queued stage query", hit.fetch("label")
  end

  # [unit] Guard catalog row 4.1: a desk measures nothing it cannot fix. A desk cut
  # after a docs merge, with the installer reporting drift, passes; the drift is a
  # line of information. The FLOOR assertions prove the stub's drift really landed.
  # [unit] Guard catalog row 4.3: the scan reads only the branch's own changes, so a
  # stale word already on the base is not this desk's failure. The control is the
  # test above: the same word in a changed file still fails.
  def test_stale_terminology_on_the_base_is_not_scanned
    write_file("docs/agents/modules/stale.md", "Use GET /api/v1/tasks?stage=queued here.\n")
    git("add", "-A")
    git("commit", "-q", "-m", "stale word on the base")
    git("update-ref", "refs/remotes/origin/accepted", head)
    task = write_task

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")

    assert status.success?, "a stale word on the base must not fail the desk:\n#{out}\n#{err}"
    assert_empty JSON.parse(out).fetch("stale_terms")
  end

  def test_installed_docs_drift_is_information_and_the_preflight_passes
    write_installer(status: 1, stderr: "ERROR: /Users/alex/projects/AGENTS.md is out of date\n")
    task = write_task

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-fetch", "--json")
    report = JSON.parse(out)
    assert_equal "drift", report.fetch("installed_docs").fetch("status"), "FLOOR: the drift must have been read"
    assert_includes report.fetch("installed_docs").fetch("message"), "AGENTS.md"

    assert status.success?, "installed-docs drift must not fail the preflight: #{report["errors"].inspect}\n#{err}"
    refute report.fetch("errors").any? { |error| error.include?("installed docs") }

    human, = run_preflight("--file", task, "--no-gh", "--no-fetch")
    assert_includes human, "Installed docs: drift (information only"
    assert_includes human, "OK session preflight passed"
  end

  # [integration] The drift REPORT must carry the installer's guidance, which is the
  # half that says who closes the drift and when. bin/install-agent-docs emits that
  # guidance AFTER one ERROR line per drifted pair and prints a passing `OK:` line
  # for every clean one; the old compaction kept the first 8 lines of the whole blob,
  # so a wide enough drift truncated the guidance away and left only the accusation —
  # exactly the shape three agents misread as a chore they owed on 2026-09-07.
  # Task preflight-invites-wrong-fix.
  def test_installed_docs_drift_message_keeps_the_ownership_guidance
    errors = (1..6).map { |i| "ERROR: /Users/alex/projects/doc-#{i}.md is out of date\n" }.join
    guidance = "This is NOT yours to fix: published by sync_agent_docs, which `bin/release ship` runs (Steffon).\n" \
               "Drift here is EXPECTED between a docs merge and the next production ship.\n" \
               "Do NOT hand-run the installer.\n" \
               "See docs/agents/modules/docs-maintenance.md § Editing The Entry Docs.\n"
    write_installer(status: 1, stderr: errors + guidance, stdout: "OK: /Users/alex/projects/CLAUDE.md matches\n")
    task = write_task

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-fetch", "--json")
    assert status.success?, "drift is information, never a blocker"

    report = JSON.parse(out)
    message = report.fetch("installed_docs").fetch("message")

    # FLOOR: the stub really ran and its drift really landed, so the assertions below
    # are reading a populated message rather than an empty string.
    assert_equal "drift", report.fetch("installed_docs").fetch("status")
    assert_includes message, "doc-1.md", "the drift report must still name what drifted"

    [
      "bin/release ship",
      "sync_agent_docs",
      "Steffon",
      "EXPECTED",
      "docs-maintenance.md"
    ].each do |needle|
      assert_includes message, needle,
        "compaction dropped the ownership guidance (#{needle.inspect}) from:\n#{message}"
    end

    refute_includes message, "OK:",
      "a failure report should not spend its budget on passing lines"
  end

  def test_github_state_and_same_file_overlap_are_reported
    task = write_task(devops: default_devops.merge("branch" => "feat/session-preflight"))
    commit_file("docs/agents/index.md", "changed\n", "feature docs")
    fake_bin = write_fake_gh

    out, err, status = run_preflight(
      "--file", task, "--no-install-docs", "--no-fetch", "--json",
      env: { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" }
    )
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal "CLEAN", report.fetch("pr").fetch("merge_state")
    assert_equal "pass", report.fetch("pr").fetch("checks").first.fetch("state")
    overlap = report.fetch("overlap").fetch("items").first
    assert_equal 6, overlap.fetch("number")
    assert_equal ["docs/agents/index.md"], overlap.fetch("files")
  end

# [unit] Guard catalog row 4.7: BLOCKED is the normal state of a PR awaiting review,
# so it is not a bad merge state. The control: DIRTY still is.
def test_a_pr_awaiting_review_is_not_a_bad_merge_state
  task = write_task(devops: default_devops.merge("branch" => "feat/session-preflight"))

  out, err, status = run_preflight(
    "--file", task, "--no-install-docs", "--no-fetch", "--json",
    env: { "PATH" => "#{write_fake_gh(merge_state: "BLOCKED")}:#{ENV.fetch("PATH", "")}" }
  )
  assert status.success?, "#{out}\n#{err}"
  report = JSON.parse(out)
  assert_equal "BLOCKED", report.fetch("pr").fetch("merge_state"), "FLOOR: the PR must have been read"
  assert_empty report.fetch("errors").grep(/merge state/)

  dirty_out, = run_preflight(
    "--file", task, "--no-install-docs", "--no-fetch", "--json",
    env: { "PATH" => "#{write_fake_gh(merge_state: "DIRTY")}:#{ENV.fetch("PATH", "")}" }
  )
  refute_empty JSON.parse(dirty_out).fetch("errors").grep(/PR merge state is DIRTY/)
end

# --- gh auth: no probe (guard catalog row 4.6) ---------------------------------

# [unit] Guard catalog row 4.6: the preflight no longer probes gh auth. `begin`
# never calls gh, and bin/submit mints and retries its own credential, so a dead
# credential here is not a blocker; the PR read reports gh's own error instead.
def test_a_dead_gh_credential_is_not_a_preflight_blocker
  task = write_task(devops: default_devops.merge("branch" => "feat/session-preflight"))
  fake_bin = write_fake_gh(auth_ok: false)

  out, err, status = run_preflight(
    "--file", task, "--no-install-docs", "--no-fetch", "--json",
    env: { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" }
  )

  assert status.success?, "#{out}\n#{err}"
  report = JSON.parse(out)
  refute report.key?("gh_auth"), "the probe is gone"
  assert_empty report.fetch("errors").grep(/gh auth/i)
end

  # --- duplicate migration installs: not the preflight's (guard catalog row 4.8) ----
  #
  # At begin the branch has no commits, so the preflight compared the base with
  # itself. bin/submit and bin/dor-check run the real check on the final diff and the
  # open sibling PRs (bin/lib/migration_collision.rb; test/lib/dor_check_migration_
  # collision_test.rb). The preflight neither checks nor reports it.

  ENGINE_MIGRATION_ORIGINAL = "20260813220000"
  BASE_INSTALL = "db/migrate/20260813221100_add_standard_user_profile_columns.studio_engine.rb"
  SECOND_INSTALL = "db/migrate/20260813223520_add_standard_user_profile_columns.studio_engine.rb"

  def test_a_duplicate_migration_install_is_left_to_the_ship
    task = write_task
    advance_base_with(BASE_INSTALL, engine_migration, "engine install lands on the base")
    commit_file(SECOND_INSTALL, engine_migration, "the same migration, a new timestamp")

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")

    assert status.success?, "#{out}\n#{err}"
    report = JSON.parse(out)
    assert_includes report.fetch("changed_files"), SECOND_INSTALL, "FLOOR: the install must be in the diff"
    refute report.key?("migration_collisions")
    assert_empty report.fetch("errors").grep(/migration/)
  end

  # [integration] The THIRD CI state at the preflight tier (task
  # detect-ci-less-stale-prs). A base-drifted PR gets ZERO check-runs and GitHub never
  # queues the workflow — but nothing said so, and the session armed a CI watcher that
  # could never fire. Preflight is where the builder meets the PR first, so it is where
  # "no CI is coming" has to be said, with a recoverable fix named.
  def test_ci_less_pr_blocks_preflight_and_names_a_recoverable_fix
    task = write_task(devops: default_devops.merge("branch" => "feat/session-preflight"))
    fake_bin = write_ci_less_gh

    out, err, status = run_preflight(
      "--file", task, "--no-install-docs", "--no-fetch", "--json",
      env: { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" }
    )
    refute status.success?, "a PR that will never get CI must block the preflight\n#{out}\n#{err}"

    report = JSON.parse(out)
    assert report.fetch("pr").fetch("ci_less"), "the PR is classified ci-less"
    blocker = report.fetch("errors").find { |e| e.match?(/NO CI/i) }
    assert blocker, "an error names the missing CI: #{report.fetch("errors").inspect}"
    # The property, not the verb (see the dor-check twin): conflict work + a way back.
    assert_match(/resolve/i, blocker, "the blocker names the conflict work")
    assert_match(/--abort/, blocker, "the blocker names a way back to a known-good state")
    assert_match(%r{origin/accepted\b}, blocker, "the blocker names the PR's actual base")
  end

  def test_a_mergeable_pr_with_checks_is_not_ci_less
    # The GUARD: the normal green PR must not trip the new alarm.
    task = write_task(devops: default_devops.merge("branch" => "feat/session-preflight"))
    fake_bin = write_fake_gh

    out, err, status = run_preflight(
      "--file", task, "--no-install-docs", "--no-fetch", "--json",
      env: { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" }
    )
    assert status.success?, "#{out}\n#{err}"
    refute JSON.parse(out).fetch("pr").fetch("ci_less")
  end

  # [integration] ROUND 2 — the fresh-push window must not be called ci-less here
  # either. GitHub answers mergeable UNKNOWN while it computes, and a brand-new head
  # SHA has zero checks in that same window; preflight runs INSIDE that window by
  # design, so an UNKNOWN must never produce the "rebase and force-push" blocker.
  def test_undetermined_mergeability_is_not_reported_as_ci_less
    task = write_task(devops: default_devops.merge("branch" => "feat/session-preflight"))
    fake_bin = write_fake_gh(merge_state: "UNKNOWN", mergeable: "UNKNOWN", rollup: "[]")

    out, err, status = run_preflight(
      "--file", task, "--no-install-docs", "--no-fetch", "--json",
      env: { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" }
    )
    assert status.success?, "an undetermined mergeability must not block\n#{out}\n#{err}"
    report = JSON.parse(out)
    refute report.fetch("pr").fetch("ci_less")
    refute(report.fetch("errors").any? { |e| e.match?(/NO CI/i) }, report.fetch("errors").inspect)
  end

  # [integration] ROUND 2 — ONE taxonomy. A DIRTY PR is a CONFLICT, and the two tools
  # must not hand the same PR different cures: preflight used to call it ci-less
  # ("rebase onto accepted and force-push") while CiStatus.view_verdict calls it
  # :conflicted ("merge release in and resolve the conflicts"). The first never
  # mentions resolving anything, so it is wrong advice for a real conflict.
  def test_a_dirty_pr_is_reported_as_a_conflict_not_as_ci_less
    task = write_task(devops: default_devops.merge("branch" => "feat/session-preflight"))
    fake_bin = write_fake_gh(merge_state: "DIRTY", mergeable: "CONFLICTING", rollup: "[]")

    out, err, status = run_preflight(
      "--file", task, "--no-install-docs", "--no-fetch", "--json",
      env: { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" }
    )
    refute status.success?, "a DIRTY PR still blocks — as a conflict\n#{out}\n#{err}"
    report = JSON.parse(out)
    refute report.fetch("pr").fetch("ci_less"), "DIRTY belongs to the conflict report, not the ci-less one"
    assert(report.fetch("errors").any? { |e| e.include?("DIRTY") }, report.fetch("errors").inspect)
    refute(report.fetch("errors").any? { |e| e.match?(/NO CI/i) },
           "a conflict must not also collect the ci-less cure")
  end

  # [integration] ROUND 4, blocker 2 — the CONJUNCTION is load-bearing in preflight
  # too, and its zero-checks guard was the unasserted copy. `combine`'s identical
  # guard is covered (mutation M11), but preflight hand-rolls its own `ci_less?` and
  # nothing pinned that half: delete `return false unless Array(checks).empty?` and a
  # PR that HAS checks + a refuted merge reports ci-less — GitHub demonstrably ran CI,
  # so "no CI will run" is a lie. A PR with checks is NEVER ci-less, whatever its merge
  # state.
  def test_a_pr_with_checks_is_never_ci_less_even_when_the_merge_is_refuted
    task = write_task(devops: default_devops.merge("branch" => "feat/session-preflight"))
    # A run that HAS reported (one passing check) AND a refuted merge — the exact
    # pairing the conjunction must keep out of ci-less.
    fake_bin = write_fake_gh(
      merge_state: "UNKNOWN", mergeable: "CONFLICTING",
      rollup: '[{ name: "test", conclusion: "SUCCESS", status: "COMPLETED", detailsUrl: "https://example.test" }]'
    )

    out, err, status = run_preflight(
      "--file", task, "--no-install-docs", "--no-fetch", "--json",
      env: { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" }
    )
    assert status.success?, "a PR that already has checks is not ci-less\n#{out}\n#{err}"
    report = JSON.parse(out)
    refute report.fetch("pr").fetch("ci_less"), "a PR with reported checks can never be ci-less"
    refute(report.fetch("errors").any? { |e| e.match?(/NO CI/i) },
           "GitHub ran CI here — the ci-less cure must not fire")
  end

  def test_docs_kind_without_shape_is_exempt_from_shape_gate
    task = write_task(devops: { "kind" => "docs", "branch" => "feat/session-preflight" })

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal true, report.fetch("ok")
    assert_empty report.fetch("errors")
    assert_equal true, report.dig("shape", "exempt")
    assert_equal "docs", report.dig("shape", "kind")
  end

  # [unit] The preflight shares bin/lib/code_diff.rb with dor-check, so the
  # behavioral files the old ALLOWLIST couldn't see (.github/, Gemfile, test/…)
  # lose the exemption HERE too, and the preview says so. Since guard catalog row
  # 4.4 the preview is information: `bin/task begin` validates the shape at create
  # and bin/dor-check refuses at ship, so the preflight passes either way.
  def test_chore_shipping_a_ci_workflow_loses_the_exemption
    task = write_task(devops: { "kind" => "chore", "branch" => "feat/session-preflight" })
    write_file(".github/workflows/ci.yml", "name: CI\non: [push]\n")

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "the shape preview is information:\n#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal false, report.dig("shape", "exempt")
    refute report.fetch("errors").any? { |error| error.include?("shape") }, report.fetch("errors").inspect

    human, = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch")
    assert_includes human, "Required tiers: none"
    refute_includes human, "Shape gate: n/a"
  end

  def test_chore_shipping_a_gemfile_bump_loses_the_exemption
    task = write_task(devops: { "kind" => "chore", "branch" => "feat/session-preflight" })
    write_file("Gemfile.lock", "GEM\n  specs:\n    rails (8.0.1)\n")

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?
    assert_equal false, JSON.parse(out).dig("shape", "exempt")
  end

  def test_docs_kind_shipping_code_loses_the_exemption
    task = write_task(devops: { "kind" => "docs", "branch" => "feat/session-preflight" })
    write_file("lib/shipped_code.rb", "# real behavioral code, not prose\n")

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?

    report = JSON.parse(out)
    assert_equal false, report.dig("shape", "exempt")
    assert_empty report.fetch("errors")
  end

  # [unit] Guard catalog row 4.4: a shape short of its metadata is reported, never a
  # failure; begin validates it at create and dor-check at ship.
  def test_missing_metadata_is_reported_not_failed
    task = write_task(devops: default_devops.reject { |key, _| key == "test_plan" })

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")

    assert status.success?, "#{out}\n#{err}"
    report = JSON.parse(out)
    assert_includes report.dig("shape", "missing_metadata"), "test_plan", "FLOOR: the gap must have been read"
    assert_empty report.fetch("errors")
  end

  def test_chore_kind_doc_only_diff_keeps_the_exemption
    task = write_task(devops: { "kind" => "chore", "branch" => "feat/session-preflight" })
    write_file("docs/agents/modules/clean-note.md", "Doc-only change keeps the exemption.\n")

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal true, report.dig("shape", "exempt")
  end

  # [unit] REGRESSION (task preflight-works-from-satellites): hub helpers —
  # bin/task and config/feature_shapes.yml — resolve from the SCRIPT'S OWN repo,
  # never from --root. A satellite/gem worktree ships neither, and the old
  # --root-relative resolution ENOENT-died `bin/task show` on every satellite
  # desk (turf-monster, twice on 2026-07-28), pushing builders to a --file
  # task-JSON dump. Proven with ZERO env seams: the script runs from a copied
  # "hub" whose bin/ carries a fake sibling task CLI and whose config carries a
  # DISTINCT shapes policy, while the inspected --root carries neither.
  def test_hub_helpers_resolve_from_script_root_not_inspected_root
    hub = File.join(@sandbox, "hub")
    FileUtils.mkdir_p(File.join(hub, "bin"))
    FileUtils.mkdir_p(File.join(hub, "config"))
    FileUtils.cp(SCRIPT, File.join(hub, "bin", "session-preflight"))
    FileUtils.cp_r(File.join(ROOT, "bin", "lib"), File.join(hub, "bin", "lib"))
    # AND THE REPO'S lib/, because bin/lib REACHES BACK INTO IT: task_tree.rb
    # requires `../../lib/cert_evidence`, and it is pulled in the moment anything on
    # this path requires bin/lib/fast_lane (ci_status.rb does, for the absolute
    # remedy commands it composes). A "copied hub" missing lib/ is not a hub — it
    # LoadErrors on require, which reads as a resolution bug in the thing under test
    # rather than as a hole in the fixture. Copying it keeps the sandbox faithful to
    # the layout the assertions below are about.
    FileUtils.cp_r(File.join(ROOT, "lib"), File.join(hub, "lib"))
    File.write(File.join(hub, "config", "feature_shapes.yml"), <<~YAML)
      defaults:
        required_metadata: [acceptance]
      shapes:
        backend:
          description: Hub-owned backend shape, distinct tiers on purpose.
          dor_tiers: [unit, hub-proof]
    YAML
    activity = {
      "activity_type" => "comment",
      "created_at" => "2026-07-28T09:00:00Z",
      "description" => "Loaded through the hub sibling CLI."
    }
    hub_task = File.join(hub, "bin", "task")
    File.write(hub_task, <<~RUBY)
      #!/usr/bin/env ruby
      if ARGV == ["show", "add-session-preflight", "--json"]
        puts #{JSON.generate("data" => task_payload(latest_activity: activity)).inspect}
      else
        warn "unexpected task args: \#{ARGV.join(" ")}"
        exit 1
      end
    RUBY
    File.chmod(0o755, hub_task)
    # Make the inspected root satellite-shaped: it never had a bin/task, and it
    # must not carry the hub's shapes policy either. Commit the removal so the
    # desk stays clean.
    git("rm", "-q", "config/feature_shapes.yml")
    git("commit", "-q", "-m", "satellite desks carry no hub config")

    out, err, status = Open3.capture3(
      SessionEnv.neutralized,
      RbConfig.ruby, File.join(hub, "bin", "session-preflight"),
      "add-session-preflight", "--root", @repo,
      "--no-gh", "--no-install-docs", "--no-fetch", "--json",
      chdir: @repo
    )
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal true, report.fetch("ok"), report.fetch("errors").inspect
    assert_equal "Loaded through the hub sibling CLI.",
                 report.dig("latest_feedback", "description"),
                 "the task record must arrive through the hub's sibling bin/task"
    assert_equal %w[unit hub-proof], report.fetch("shape").fetch("dor_tiers"),
                 "the shape taxonomy must come from the HUB's config — --root has none"
    assert_empty report.fetch("warnings").grep(/feature_shapes/), report.fetch("warnings").inspect
  end

  def test_live_task_show_contract_reports_latest_feedback
    write_fake_task_cli(latest_activity: {
      "activity_type" => "qa_feedback",
      "created_at" => "2026-06-26T18:55:11Z",
      "description" => "Live board feedback should be visible."
    })

    out, err, status = run_preflight("add-session-preflight", "--no-gh", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal "qa_feedback", report.dig("latest_feedback", "activity_type")
    assert_equal "Live board feedback should be visible.", report.dig("latest_feedback", "description")
  end

  # THE HARNESS SELF-TEST — the board fallback, proven pinned.
  #
  # A fixture with NO latest_activity is the shape that FIRES the fallback, and the
  # fallback is a direct Net::HTTP call to TASK_API_BASE, not a call through
  # SESSION_PREFLIGHT_TASK_BIN. Before the floor, exactly two tests in this file
  # pinned that base; every other one avoided the call only because its fixture
  # happened to carry an activity with a description. Containment by fixture shape
  # is one edit from gone, and the edit looks harmless.
  #
  # The receipt is POSITIVE: the run must report the fallback FAILING against the
  # pinned loopback host. "No warning" would be the wrong assertion — that is also
  # what a successful call to PRODUCTION looks like.
  #
  # AGENT_API_SECRET is supplied because the fallback returns early without one, and
  # CI has none (no .env, no 1Password). Without it this would pass for a reason
  # that has nothing to do with the pin. It can only ever be offered to loopback.
  def test_the_board_fallback_is_pinned_at_the_floor_not_production
    write_fake_task_cli

    out, err, status = run_preflight("add-session-preflight", "--no-gh", "--no-fetch", "--json",
                                     env: { "AGENT_API_SECRET" => "pin-proof-not-a-real-secret" })
    assert status.success?, "#{out}\n#{err}"

    warning = JSON.parse(out).fetch("warnings").grep(/latest task activity fallback failed/).first
    refute_nil warning,
               "the activities fallback did not run, so this proves nothing about the pin. It " \
               "fires only when the record carries no latest_activity with a description — check " \
               "the fixture still has that shape."
    assert_includes warning, "127.0.0.1",
                    "the fallback reached #{warning.inspect} instead of the pinned loopback base. " \
                    "bin/session-preflight defaults TASK_API_BASE to https://mcritchie.studio, so " \
                    "anything but 127.0.0.1 here is a live read of the production board."
  end

  def test_live_task_show_falls_back_to_activities_api_for_latest_feedback
    write_fake_task_cli
    activity = {
      "activity_type" => "qa_feedback",
      "created_at" => "2026-06-26T19:41:52Z",
      "description" => "Live activities feedback should be visible before serializer deploy."
    }

    with_activity_api(activity) do |base_url|
      out, err, status = run_preflight(
        "add-session-preflight", "--no-gh", "--no-fetch", "--json",
        env: {
          "AGENT_API_SECRET" => "test-secret",
          "TASK_API_BASE" => base_url
        }
      )
      assert status.success?, "#{out}\n#{err}"

      report = JSON.parse(out)
      assert_equal "qa_feedback", report.dig("latest_feedback", "activity_type")
      assert_equal "Live activities feedback should be visible before serializer deploy.",
                   report.dig("latest_feedback", "description")
      assert_empty report.fetch("warnings").grep(/latest task activity fallback failed/)
    end
  end

  def test_live_task_show_falls_back_to_clarification_activity
    write_fake_task_cli
    activity = {
      "activity_type" => "clarification",
      "created_at" => "2026-06-26T19:42:31Z",
      "description" => "Can you clarify whether this blocks release?"
    }

    with_activity_api(activity) do |base_url|
      out, err, status = run_preflight(
        "add-session-preflight", "--no-gh", "--no-fetch", "--json",
        env: {
          "AGENT_API_SECRET" => "test-secret",
          "TASK_API_BASE" => base_url
        }
      )
      assert status.success?, "#{out}\n#{err}"

      report = JSON.parse(out)
      assert_equal "clarification", report.dig("latest_feedback", "activity_type")
      assert_equal "Can you clarify whether this blocks release?",
                   report.dig("latest_feedback", "description")
      assert_empty report.fetch("warnings").grep(/latest task activity fallback failed/)
    end
  end

  private

  def run_preflight(*args, env: {})
    # The hub-helper seams point the script back at the sandbox: production
    # resolves bin/task and config/feature_shapes.yml from the script's OWN
    # repo (the hub), which for a test would be the REAL board CLI and the REAL
    # shapes policy. The zero-seam anchoring itself is proven separately in
    # test_hub_helpers_resolve_from_script_root_not_inspected_root.
    #
    # THE TWO SEAMS ABOVE ARE NOT THE WHOLE REACH, and believing they were is what
    # left this file seamed BY CONVENTION rather than by helper. Two things escaped
    # them:
    #
    #   * THE BOARD FALLBACK. When a task record carries no latest_activity with a
    #     description, bin/session-preflight calls the tasks API directly over
    #     Net::HTTP (fetch_latest_task_activity), NOT through
    #     SESSION_PREFLIGHT_TASK_BIN — and TASK_API_BASE defaults to
    #     https://mcritchie.studio. Exactly two tests here pinned TASK_API_BASE;
    #     every other test dodges the call only by FIXTURE SHAPE, because the
    #     default fixture happens to supply an activity with a description. One
    #     fixture edit re-opens it. That is not containment, that is luck with good
    #     manners.
    #   * gh AND git. Each gh-touching test plants its own fake on PATH or passes
    #     --no-gh, and most (not all) pass --no-fetch. Same shape: correct in every
    #     test that remembered.
    #
    # So the floor (test/support/outbound_seams.rb) is applied here, once, for
    # every spawn: an unroutable board, a sealed gh/op/heroku on PATH, and a
    # recording refusal for git's ssh and credential paths. `env` still merges LAST,
    # so the tests that plant their own fake gh keep winning.
    seams = {
      "SESSION_PREFLIGHT_TASK_BIN" => File.join(@repo, "bin", "task"),
      "SESSION_PREFLIGHT_SHAPES_PATH" => File.join(@repo, "config", "feature_shapes.yml")
    }
    Open3.capture3(
      OutboundSeams.env(seams.merge(env)),
      RbConfig.ruby, SCRIPT, "--root", @repo, *args,
      chdir: @repo
    )
  end

  def write_task(stage: "building", devops: default_devops, latest_activity: nil)
    path = File.join(@sandbox, "task.json")
    File.write(path, "#{JSON.pretty_generate("data" => task_payload(stage: stage, devops: devops, latest_activity: latest_activity))}\n")
    path
  end

  def task_payload(stage: "building", devops: default_devops, latest_activity: nil)
    payload = {
      "slug" => "add-session-preflight",
      "title" => "Add Session Preflight",
      "stage" => stage,
      "metadata" => { "devops" => devops },
      "task_url" => "https://mcritchie.studio/tasks/add-session-preflight"
    }
    payload["latest_activity"] = latest_activity if latest_activity
    payload
  end

  def write_fake_task_cli(latest_activity: nil)
    write_file("bin/task", <<~RUBY)
      #!/usr/bin/env ruby
      if ARGV == ["show", "add-session-preflight", "--json"]
        puts #{JSON.generate("data" => task_payload(latest_activity: latest_activity)).inspect}
      else
        warn "unexpected task args: \#{ARGV.join(" ")}"
        exit 1
      end
    RUBY
    File.chmod(0o755, File.join(@repo, "bin", "task"))
  end

  def with_activity_api(activity)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets.to_s
        headers = {}
        while (line = client.gets)
          break if line == "\r\n"

          key, value = line.split(":", 2)
          headers[key.to_s.downcase] = value.to_s.strip
        end
        client.read(headers.fetch("content-length", "0").to_i)

        body = if request_line.start_with?("POST /api/v1/auth ")
          JSON.generate("token" => "test-token")
        elsif request_line.start_with?("GET /api/v1/activities?")
          JSON.generate("data" => [activity], "meta" => { "page" => 1, "per_page" => 20, "total" => 1 })
        else
          JSON.generate("error" => "unexpected request: #{request_line.strip}")
        end
        status = body.include?("unexpected request") ? "404 Not Found" : "200 OK"
        client.write "HTTP/1.1 #{status}\r\n"
        client.write "Content-Type: application/json\r\n"
        client.write "Content-Length: #{body.bytesize}\r\n"
        client.write "Connection: close\r\n\r\n"
        client.write body
        client.close
      rescue IOError, Errno::EBADF
        break
      ensure
        client&.close unless client&.closed?
      end
    end

    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.join(1)
    thread&.kill if thread&.alive?
  end

  def default_devops
    {
      "kind" => "chore",
      "shape" => "backend",
      "repositories" => ["mcritchie-studio"],
      "risk_tags" => ["devops", "docs"],
      "acceptance" => ["Preflight reports blocker feedback"],
      "test_plan" => ["[unit] command output"],
      "branch" => "feat/session-preflight"
    }
  end

  def write_feature_shapes
    write_file("config/feature_shapes.yml", <<~YAML)
      defaults:
        required_metadata: [acceptance, repositories, risk_tags, test_plan]
      shapes:
        backend:
          description: Backend command.
          dor_tiers: [unit, integration]
          required_metadata: [acceptance, repositories, risk_tags, test_plan]
    YAML
  end

  # The stub stands in for bin/install-agent-docs, which is BASH. Keep the stub
  # bash too: a `#!/usr/bin/env ruby` stub inherits this suite's RUBYOPT/BUNDLE_*
  # and prints a dozen bundler "already initialized constant" warnings to stderr
  # before its own output — noise the real script never emits, which then occupies
  # the drift message the preflight reports and hides what the stub actually said.
  def write_installer(status:, stderr: "", stdout: "")
    write_file("bin/install-agent-docs", <<~SH)
      #!/bin/bash
      cat >&2 <<'PREFLIGHT_STUB_STDERR'
      #{stderr.chomp}
      PREFLIGHT_STUB_STDERR
      cat <<'PREFLIGHT_STUB_STDOUT'
      #{stdout.chomp}
      PREFLIGHT_STUB_STDOUT
      exit #{status}
    SH
    File.chmod(0o755, File.join(@repo, "bin", "install-agent-docs"))
  end

  # A PR GitHub will never run CI for: ZERO check-runs plus a merge it will not
  # confirm (task detect-ci-less-stale-prs). `mergeable: "CONFLICTING"` with an empty
  # rollup is the shape a base-drifted PR actually reports.
  def write_ci_less_gh
    write_fake_gh(merge_state: "UNKNOWN", mergeable: "CONFLICTING", rollup: "[]")
  end

  def write_fake_gh(merge_state: "CLEAN", mergeable: "MERGEABLE", rollup: nil,
                    sibling_files: ["docs/agents/index.md"], auth_ok: true)
    rollup ||= '[{ name: "test", conclusion: "SUCCESS", status: "COMPLETED", detailsUrl: "https://example.test" }]'
    dir = File.join(@sandbox, "fake-bin")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      case ARGV
      in ["api", "rate_limit"]
        # The liveness probe bin/session-preflight uses. NOT `gh api user`, which an
        # App installation token cannot call at all.
        #{auth_ok ? "puts JSON.generate(rate: { limit: 5000, remaining: 4999 })" : "warn \"gh: Bad credentials (HTTP 401)\"; exit 1"}
      in ["pr", "view", ref, "--json", fields]
        if fields == "files"
          sibling = #{JSON.generate(sibling_files)}.map { |p| { path: p } }
          files = ref == "6" ? sibling : [{ path: "README.md" }]
          puts JSON.generate(files: files)
        else
          puts JSON.generate(
            number: 5,
            title: "Add Session Preflight",
            url: "https://github.com/McRitchie-Studio/mcritchie-studio/pull/5",
            headRefName: "feat/session-preflight",
            baseRefName: "accepted",
            mergeable: "#{mergeable}",
            mergeStateStatus: "#{merge_state}",
            statusCheckRollup: #{rollup}
          )
        end
      in ["pr", "list", "--state", state, "--limit", _limit, "--json", _fields]
        if state == "open"
          puts JSON.generate([
            { number: 5, title: "Current", url: "https://example.test/5", headRefName: "feat/session-preflight", updatedAt: "now" },
            { number: 6, title: "Sibling", url: "https://example.test/6", headRefName: "feat/sibling", updatedAt: "now" }
          ])
        else
          puts JSON.generate([])
        end
      else
        warn "unexpected gh args: \#{ARGV.join(" ")}"
        exit 1
      end
    RUBY
    File.chmod(0o755, path)
    dir
  end

  def write_file(relative, body)
    path = File.join(@repo, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def commit_file(relative, body, message)
    write_file(relative, body)
    git("add", "-A")
    git("commit", "-q", "-m", message)
    head
  end

  # Land a file on the BASE ref without leaving the branch behind it — the commit and
  # origin/release move together, so drift stays 0 and the only blocker a test can
  # observe is the one it is about.
  def advance_base_with(relative, body, message)
    commit_file(relative, body, message)
    git("update-ref", "refs/remotes/origin/release", head)
  end

  # What `rails studio_engine:install:migrations` writes: the gem's migration verbatim,
  # with ONE added first line recording the engine original it was copied from. Verified
  # against all three 2026-08-13 consumer copies, which were byte-identical apart from it.
  def engine_migration(original: ENGINE_MIGRATION_ORIGINAL, klass: "AddStandardUserProfileColumns")
    <<~RUBY
      # This migration comes from studio_engine (originally #{original})
      class #{klass} < ActiveRecord::Migration[8.1]
        def change
          add_column :users, :display_name, :string
        end
      end
    RUBY
  end

  def git(*args)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", *args, chdir: @repo)
    assert status.success?, "git #{args.join(" ")} failed\n#{out}\n#{err}"
    out
  end

  def head
    git("rev-parse", "HEAD").strip
  end
end
