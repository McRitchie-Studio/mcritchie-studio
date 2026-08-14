# frozen_string_literal: true

# [unit] The duplicate-migration-install detector. Pure by construction — the caller
# supplies paths, first lines, and git output — so every rule is asserted with no
# network, no gh, and no repo.
#
# THE SHAPE UNDER TEST, reproduced from the live 2026-08-13/14 incidents: two files
# with DIFFERENT names and DIFFERENT timestamps that install ONE engine migration.
# Git merges both cleanly (only db/schema.rb conflicts), and Rails then raises
# DuplicateMigrationNameError on every db:migrate — including the Heroku release
# phase — because it groups by CLASS NAME, not filename.
#
#   ruby -Itest test/lib/migration_collision_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../bin/lib/migration_collision"

class MigrationCollisionTest < Minitest::Test
  HEADER = "# This migration comes from studio_engine (originally 20260813220000)"
  # The two real turf-monster copies, verified byte-identical apart from this line.
  MINE   = "db/migrate/20260813223520_add_standard_user_profile_columns.studio_engine.rb"
  THEIRS = "db/migrate/20260813221100_add_standard_user_profile_columns.studio_engine.rb"

  def id(path, head = nil)
    MigrationCollision.identity(path, head)
  end

  def source(installs, kind: "pr", number: 313, label: "Turf adopts profile migration")
    { "label" => label, "kind" => kind, "number" => number,
      "url" => "https://github.com/o/r/pull/#{number}", "installs" => installs }
  end

  # --- identity ---------------------------------------------------------------

  def test_identity_parses_an_installed_engine_migration
    ident = id(MINE, HEADER)
    assert_equal "20260813223520", ident["version"]
    assert_equal "add_standard_user_profile_columns", ident["name"]
    assert_equal "studio_engine", ident["scope"]
    assert_equal "AddStandardUserProfileColumns", ident["class_name"]
    assert_equal "studio_engine:20260813220000", ident["origin_key"],
                 "the provenance header is the second, independent key"
  end

  # A host-authored migration has no scope and no provenance — it still gets a class
  # key, because two host migrations named alike raise exactly the same error.
  def test_identity_parses_a_plain_host_migration
    ident = id("db/migrate/20260814010101_add_foo_to_bars.rb")
    assert_equal "add_foo_to_bars", ident["name"]
    assert_nil ident["scope"]
    assert_nil ident["origin_key"]
    assert_equal "AddFooToBars", ident["class_name"]
  end

  def test_identity_ignores_paths_that_are_not_migrations
    assert_nil id("app/models/user.rb")
    assert_nil id("db/schema.rb")
    assert_nil id("db/migrate/README.md")
    assert_nil id("db/seeds.rb")
  end

  # An engine's OWN migrations live in the gem, not in a host db/migrate — but a
  # nested checkout still parses, so the check works from any repo root.
  def test_migration_paths_accepts_a_nested_db_migrate
    assert_equal ["engines/studio/db/migrate/20260101000000_add_a.rb"],
                 MigrationCollision.migration_paths(%w[engines/studio/db/migrate/20260101000000_add_a.rb
                                                       engines/studio/app/models/a.rb])
  end

  # --- THE DEFECT -------------------------------------------------------------

  # turf-monster #312 vs #313: one engine migration, two host timestamps, two
  # filenames. The class key catches it from the FILENAMES ALONE, which is what makes
  # the check affordable against `gh pr list --json files`.
  def test_two_installs_of_one_migration_collide_on_the_class_key
    items = MigrationCollision.report([id(MINE, HEADER)], [source([id(THEIRS)])])

    assert_equal 1, items.size
    assert_equal "class", items.first["key"]
    assert_equal MINE, items.first["mine"]["path"]
    assert_equal THEIRS, items.first["theirs"]["path"]
  end

  # The second key earns its place here: a RENAMED install raises no
  # DuplicateMigrationNameError (the class names differ) but still applies one schema
  # change twice, and only the provenance header can see it.
  def test_a_renamed_install_still_collides_on_the_provenance_key
    renamed = "db/migrate/20260813221100_add_standard_user_profile_cols.studio_engine.rb"
    items = MigrationCollision.report([id(MINE, HEADER)], [source([id(renamed, HEADER)])])

    assert_equal 1, items.size
    assert_equal "origin", items.first["key"]
  end

  # Class-key matches raise on db:migrate; origin-key matches merely double-apply. The
  # one that breaks the deploy is read first.
  def test_class_collisions_sort_ahead_of_provenance_collisions
    renamed = "db/migrate/20260813221100_add_standard_user_profile_cols.studio_engine.rb"
    items = MigrationCollision.report(
      [id(MINE, HEADER)],
      [source([id(renamed, HEADER)], number: 1), source([id(THEIRS)], number: 2)]
    )
    assert_equal %w[class origin], items.map { |i| i["key"] }
  end

  # --- THE NEGATIVE CONTROLS --------------------------------------------------
  #
  # These matter more than the detection. A check that flagged every normal install
  # would be worse than the bug it prevents.

  def test_a_legitimate_single_install_does_not_collide
    others = [source([id("db/migrate/20260101000000_create_widgets.rb"),
                      id("db/migrate/20260202000000_add_bells_to_widgets.rb")])]
    assert_empty MigrationCollision.report([id(MINE, HEADER)], others)
  end

  # A whole healthy tree — many installs from one engine, each a DIFFERENT migration —
  # must stay silent. Sharing an engine is not sharing a migration.
  def test_many_installs_from_one_engine_do_not_collide_with_each_other
    installs = [
      id("db/migrate/20260812195216_create_studio_email_settings.studio_engine.rb",
         "# This migration comes from studio_engine (originally 20260812190000)"),
      id("db/migrate/20260812205132_add_copy_to_studio_email_settings.studio_engine.rb",
         "# This migration comes from studio_engine (originally 20260812210000)"),
      id("db/migrate/20260812212510_add_subject_to_studio_email_settings.studio_engine.rb",
         "# This migration comes from studio_engine (originally 20260812220000)")
    ]
    assert_empty MigrationCollision.report(installs, [source(installs, kind: "self")])
  end

  # THE INVARIANT: same path is an EDIT, and git conflicts on it honestly. Reporting it
  # would fire on every PR that merely touches a migration already on the base.
  def test_the_same_path_on_both_sides_is_never_a_collision
    assert_empty MigrationCollision.report([id(MINE, HEADER)], [source([id(MINE, HEADER)])])
  end

  def test_no_migrations_in_the_diff_reports_nothing
    assert_empty MigrationCollision.report([], [source([id(MINE, HEADER)])])
    assert_empty MigrationCollision.report(nil, [source([id(MINE, HEADER)])])
  end

  # A branch colliding with ITSELF (a mis-resolved rebase) is reported ONCE as a pair,
  # not twice as A→B and B→A.
  def test_a_within_branch_collision_is_reported_once
    ours = [id(MINE, HEADER), id(THEIRS, HEADER)]
    items = MigrationCollision.report(ours, [source(ours, kind: "self")])
    assert_equal 1, items.size
  end

  # --- the message ------------------------------------------------------------

  def test_lines_name_both_files_the_pr_and_the_fix
    text = MigrationCollision.lines(
      MigrationCollision.report([id(MINE, HEADER)], [source([id(THEIRS)])])
    ).join("\n")

    assert_includes text, MINE, "the operator must see WHICH two files collide"
    assert_includes text, THEIRS
    assert_includes text, "PR #313", "and WHICH PR carries the other one"
    assert_includes text, "AddStandardUserProfileColumns", "named by the class Rails groups on"
    assert_includes text, "DuplicateMigrationNameError", "and the actual consequence"
    assert_includes text, "Heroku release phase", "which is a DEPLOY break, not a local one"
    assert_includes text, "the other DROPS it", "and the resolution all three incidents used"
  end

  def test_lines_are_empty_when_nothing_collides
    assert_empty MigrationCollision.lines([])
    refute MigrationCollision.blocking?([])
  end

  def test_any_finding_blocks
    assert MigrationCollision.blocking?(MigrationCollision.report([id(MINE, HEADER)], [source([id(THEIRS)])]))
  end

  # --- git output parsing -----------------------------------------------------

  def test_parse_ls_tree_keeps_only_migrations
    output = ["db/migrate/20260813221100_add_standard_user_profile_columns.studio_engine.rb",
              "db/migrate/README.md", ""].join("\n")
    assert_equal [THEIRS], MigrationCollision.parse_ls_tree(output)
  end

  # `git grep -z` NUL-separates the fields; the ref prefix is stripped so the key
  # matches the plain repo-relative path ls-tree hands back. NUL is built from 0.chr
  # so the fixture can never be mistaken for whitespace, and the source stays text.
  NUL = 0.chr

  def test_parse_grep_reads_provenance_headers
    ref = "origin/accepted"
    output = "#{ref}:#{THEIRS}#{NUL}1#{NUL}#{HEADER}\n"
    headers = MigrationCollision.parse_grep(output, ref)
    assert_equal({ THEIRS => HEADER }, headers)
  end

  # A match on a line other than the first is not provenance — the header is the file's
  # FIRST line, and a migration merely mentioning the phrase must not be mis-keyed.
  def test_parse_grep_ignores_matches_below_the_first_line
    ref = "origin/accepted"
    output = "#{ref}:#{THEIRS}#{NUL}42#{NUL}# see: This migration comes from studio_engine (originally 1)\n"
    assert_empty MigrationCollision.parse_grep(output, ref)
  end

  # `git grep` exits non-zero with no output when nothing matches; that is a normal
  # empty result (a repo with no engine installs), not an error.
  def test_ref_installs_survives_a_repo_with_no_provenance_headers
    runner = lambda do |args|
      args.first == "ls-tree" ? "db/migrate/20260814010101_add_foo_to_bars.rb\n" : ""
    end
    installs = MigrationCollision.ref_installs("origin/accepted", &runner)
    assert_equal ["AddFooToBars"], installs.map { |i| i["class_name"] }
  end

  def test_ref_installs_with_no_ref_asks_nothing
    called = false
    assert_empty MigrationCollision.ref_installs(nil) { |_| called = true; "" }
    refute called, "a missing base ref must not shell out"
  end

  # A DELETED migration is not an install. Reading one as an install would invent a
  # collision against the copy still on the base ref, at a different path.
  def test_local_installs_skips_files_the_reader_cannot_read
    installs = MigrationCollision.local_installs([MINE, THEIRS]) do |path|
      path == MINE ? HEADER : nil
    end
    assert_equal [MINE], installs.map { |i| i["path"] }
  end
end
