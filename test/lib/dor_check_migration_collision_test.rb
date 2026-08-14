# frozen_string_literal: true

# bin/dor-check's DUPLICATE MIGRATION INSTALL refusal. Standalone (no Rails — it
# shells out to the script with --file fixtures):
#   ruby -Itest test/lib/dor_check_migration_collision_test.rb
#
# WHY THE MERGE GATE NEEDS ITS OWN COPY. Rails groups migrations by CLASS NAME, so
# two files under different timestamps that parse to one class raise
# DuplicateMigrationNameError on every db:migrate — including the Heroku release
# phase. bin/session-preflight has reported this since it was written, and bin/ship
# at handoff, but BOTH judge one branch against the base at the moment they run.
# Neither can see the case that actually bit on 2026-08-13: two branches, each
# honestly clean when it was certified, that collide only once the first one merges.
# Preflight ran before the sibling PR existed. The gate before `accepted` takes both
# is the only reader positioned to refuse, which is why `test_the_second_pr_sees_the
# _first` is the load-bearing test in this file and not a nicety.
#
# THE CONTROL MATTERS AS MUCH AS THE REFUSALS. A gate that refuses everything would
# pass every red test here, so `test_a_lone_migration_is_not_a_collision` and the
# rename case exist to prove it still lets correct work through — the rename case
# being the one a naive implementation gets wrong, because `git diff` with rename
# detection ON hides the deleted path and the branch then collides with its own old
# copy on the base ref.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class DorCheckMigrationCollisionTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/77"

  BASE_MIGRATION = "db/migrate/20260101000000_add_widget_columns.rb"
  # A DIFFERENT timestamp, the SAME migration name — so it is a different FILE and an
  # identical Rails class. That pair is precisely what raises, and precisely what a
  # filename-keyed check (same-file overlap) cannot see.
  NEW_MIGRATION  = "db/migrate/20260814000000_add_widget_columns.rb"
  UNRELATED      = "db/migrate/20260814000000_add_orders_table.rb"

  # ── fixtures ────────────────────────────────────────────────────────────────

  def task(changed)
    {
      "slug" => "task-migration-collision", "title" => "T",
      "metadata" => { "devops" => {
        "kind" => "bug", "shape" => "backend", "pr_url" => PR_URL,
        "acceptance" => ["refuse a colliding migration at review"],
        "repositories" => ["myapp"],
        "risk_tags" => ["release-phase"],
        "test_plan" => ["[unit] collision", "[integration] sibling pr"],
        "post_deploy_cmd" => "none",
        "checks_run" => ["[unit] collision", "[integration] sibling pr"],
        "changed" => changed
      } }
    }
  end

  # A real git repo whose HEAD (the diff base) already carries `paths`. The base-ref
  # leg shells out to git for real, so a stubbed tree would not exercise it.
  def repo_with(*paths)
    dir = Dir.mktmpdir
    system("git", "-C", dir, "init", "-q", err: File::NULL)
    system("git", "-C", dir, "config", "user.email", "t@example.com")
    system("git", "-C", dir, "config", "user.name", "T")
    paths.each do |path|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "class AddWidgetColumns < ActiveRecord::Migration[8.1]\nend\n")
    end
    system("git", "-C", dir, "add", "-A", err: File::NULL)
    system("git", "-C", dir, "commit", "-qm", "base", err: File::NULL)
    dir
  end

  # Drives the gate with the migration status seam supplying what the change ADDS and
  # REMOVES, and the sibling seam supplying the other open PRs.
  def dor_check(root, added:, removed: [], siblings: nil)
    records = added.map { |p| "added\t#{p}" } + removed.map { |p| "removed\t#{p}" }
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task(added)))
      env = SessionEnv.neutralized(
        "DOR_CHECK_DIFF_ROOT" => root,
        "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => (added + removed).join("\n"),
        "DOR_CHECK_PR_MIGRATIONS" => records.join("\n"),
        "DOR_CHECK_SIBLING_PRS" => (siblings ? JSON.generate(siblings) : "[]"),
        "DOR_CHECK_PR_FILES" => (added + removed).join("\n"),
        "DOR_CHECK_CI_STATUS" => "green",
        "DOR_CHECK_SUITE_EVIDENCE" => "ok"
      )
      out = IO.popen(env, "#{BIN} --file #{path} --json 2>/dev/null", &:read)
      [JSON.parse(out), $?.exitstatus]
    end
  end

  COLLISION = /duplicate migration install/i

  # The refusal lives in the `errors` array of the --json verdict, not in a prose
  # note — asserting against the wrong key is how the first cut of this file "passed"
  # while the gate found nothing at all.
  def errors_of(verdict)
    Array(verdict["errors"]).join(" | ")
  end

  # ── [unit] the base-ref leg ─────────────────────────────────────────────────

  def test_a_migration_colliding_with_the_base_ref_is_refused
    root = repo_with(BASE_MIGRATION)
    verdict, code = dor_check(root, added: [NEW_MIGRATION])

    assert_match COLLISION, errors_of(verdict),
                 "two files resolving to AddWidgetColumns must be refused before accepted takes both"
    refute verdict["ready"], "a colliding migration is not merge-ready"
    assert_equal 1, code
  ensure
    FileUtils.remove_entry(root) if root
  end

  # THE CONTROL. Without it every assertion above is satisfied by a gate that simply
  # always refuses.
  def test_a_lone_migration_is_not_a_collision
    root = repo_with(BASE_MIGRATION)
    verdict, = dor_check(root, added: [UNRELATED])

    refute_match COLLISION, errors_of(verdict),
                 "a migration whose class exists nowhere else must pass"
  ensure
    FileUtils.remove_entry(root) if root
  end

  # ── [unit] rename subtracts base-ref deletions with --no-renames ────────────

  def test_a_renamed_migration_is_not_a_false_collision
    # The change MOVES the migration: same class, new timestamp, and the old file is
    # deleted in the same diff. Under `git diff -M` the deletion is invisible (one R
    # record), the base-ref copy still looks live, and the branch collides with
    # itself — a false refusal on a correct change. Subtracting what the change
    # REMOVES from the base ref is the whole fix, and this is the test that fails
    # without it.
    root = repo_with(BASE_MIGRATION)
    verdict, code = dor_check(root, added: [NEW_MIGRATION], removed: [BASE_MIGRATION])

    refute_match COLLISION, errors_of(verdict),
                 "the base-ref copy is DELETED by this same change — it cannot collide with its replacement"
    assert_equal 0, code, "a rename must stay merge-ready: #{errors_of(verdict)}"
  ensure
    FileUtils.remove_entry(root) if root
  end

  # ── [integration] the second reviewed PR sees the first ────────────────────

  def test_the_second_pr_sees_the_first
    # THE INCIDENT'S SHAPE. Neither branch touches the other's files, so same-file
    # overlap reports nothing; neither is on the base ref yet, so the local leg
    # reports nothing. Both were certified green. Whichever merges first, the second
    # one breaks the release phase — so the gate has to read the OTHER open PR.
    root = repo_with # base carries no migrations at all
    siblings = [{ "number" => 91, "title" => "Add widget columns", "headRefName" => "feat/other",
                  "url" => "https://github.com/McRitchie-Studio/myapp/pull/91",
                  "files" => [BASE_MIGRATION] }]
    verdict, code = dor_check(root, added: [NEW_MIGRATION], siblings: siblings)

    assert_match COLLISION, errors_of(verdict),
                 "an open sibling PR installing the same class must refuse this one"
    assert_match(/91/, errors_of(verdict),
                 "the refusal must name WHICH PR carries the other copy, or it is not actionable")
    refute verdict["ready"]
    assert_equal 1, code
  ensure
    FileUtils.remove_entry(root) if root
  end

  # A release batch PR re-lists every migration already on `accepted`. Counting those
  # would refuse every branch for the duration of a sweep.
  def test_a_release_batch_pr_is_not_a_collision_source
    root = repo_with
    siblings = [{ "number" => 99, "title" => "Promote accepted into release", "headRefName" => "accepted",
                  "url" => "https://github.com/McRitchie-Studio/myapp/pull/99",
                  "files" => [BASE_MIGRATION] }]
    verdict, = dor_check(root, added: [NEW_MIGRATION], siblings: siblings)

    refute_match COLLISION, errors_of(verdict),
                 "the accepted->release batch head carries copies that are already accounted for"
  ensure
    FileUtils.remove_entry(root) if root
  end
end
