# frozen_string_literal: true

require "test_helper"

# [unit] The orphan-database sweep must never nominate a LIVE desk.
#
# THE TRAP THIS EXISTS FOR, from test/support/cert_database_reaper.rb: "a pattern
# is not an identity". bounded_db_slug truncates an over-long slug and suffixes it
# with a hash, so a REAL, LIVE desk with a long name owns a database of exactly
# the shape a stranded one has. There is no pattern that separates them. A sweep
# that drops "everything matching the per-desk pattern" WILL eventually drop a
# live desk — that file records an earlier cut at a related purge that "once
# bricked every release".
#
# So the sweep is an INVERTED CLOSED SET: enumerate the live desks, compute what
# they OWN, and treat everything else of that shape as a candidate. The direction
# matters — identity comes from the desks that exist, never from the name.
class OrphanDbSweepTest < ActiveSupport::TestCase
  def script
    @script ||= begin
      src = File.read(Rails.root.join("bin/agent-worktree")).sub(/^\s*main\b.*$/, "")
      host = Object.new
      host.instance_eval(src, "bin/agent-worktree")
      host
    end
  end

  def record_for(slug, task, db: nil)
    { app: { "slug" => slug, "repo" => "/tmp/#{slug}" }, task: task, db_name: db }
  end

  # THE LONG-SLUG CASE, which is the whole reason for the closed set. A desk whose
  # task name overflows the identifier limit owns a TRUNCATED, HASH-SUFFIXED
  # database — indistinguishable by shape from a stranded one.
  test "a long-slug desk owns the hashed name it actually has" do
    long = "a-very-long-task-slug-that-will-certainly-overflow-the-postgres-identifier-limit"
    owned = script.desk_owned_db_names(record_for("turf-monster", long))
    expected = script.worktree_db_name("turf-monster", long)

    assert_includes owned, expected,
                    "the keep set does not contain the name this desk really owns, so the sweep " \
                    "would nominate a LIVE desk's database as an orphan"
    assert_operator expected.length, :<=, 63, "the derived name must fit Postgres' identifier limit"
    refute_equal "turf_monster_development_#{long.tr('-', '_')}", expected,
                 "this slug was expected to OVERFLOW and be hashed; if it no longer does, this " \
                 "test is not exercising the trap it was written for"
  end

  # The _test_ sibling and the parallel shards belong to the desk too. Shards were
  # 84 of the 498 first measured, so a keep set without them nominates a live
  # desk's shards.
  test "a desk owns its test sibling as well as its dev database" do
    owned = script.desk_owned_db_names(record_for("turf-monster", "some-task"))

    assert_includes owned, "turf_monster_development_some_task"
    assert_includes owned, "turf_monster_test_some_task",
                    "the _test_ sibling is minted from the same slug and belongs to the desk"
  end

  # The env is authoritative when present: a desk whose database was renamed by
  # hand still owns whatever its own env records.
  test "a recorded db_name is kept even when it does not match the derived one" do
    owned = script.desk_owned_db_names(record_for("turf-monster", "x", db: "hand_renamed_development_thing"))

    assert_includes owned, "hand_renamed_development_thing"
    assert_includes owned, "hand_renamed_test_thing"
  end

  test "a record with no task and no recorded name owns nothing" do
    assert_empty script.desk_owned_db_names(record_for("turf-monster", nil))
  end

  # ---- the refusals -------------------------------------------------------
  #
  # ABSENCE OF SIGNAL IS NOT PERMISSION. This sweep deletes by ABSENCE from the
  # keep set, so anything that makes a live desk invisible must stop the whole
  # run — not just skip that repo.

  test "the sweep refuses when a repo exists but cannot be read" do
    src = File.read(Rails.root.join("bin/agent-worktree"))
    body = src[/def orphan_sweep_keep_set(.*?)^end/m, 1]

    refute_nil body, "orphan_sweep_keep_set moved — re-point this test rather than deleting it"
    assert_match(/unreadable << repo/, body,
                 "a repo whose directory exists but carries no .git may hold desks this sweep " \
                 "cannot see, and their databases would look orphaned")
  end

  # BUT an absent repo is not unreadable — it is absent, owns no desks, and
  # endangers nothing. tax-studio is registered-but-never-cloned and sits in
  # exactly that state; treating it as unreadable made the sweep refuse FOREVER,
  # which is how a safety rule becomes a rule nobody can satisfy.
  test "a repo that was never cloned does not block the sweep" do
    src = File.read(Rails.root.join("bin/agent-worktree"))
    body = src[/def orphan_sweep_keep_set(.*?)^end/m, 1]

    assert_match(/next unless Dir\.exist\?\(repo\)/, body,
                 "an absent repo aborts the run; a registered-but-uncloned repo would make this " \
                 "sweep permanently unusable")
  end

  # DRY RUN BY DEFAULT. The command must not be able to delete without --yes.
  test "the sweep is dry by default and needs an explicit opt-in to delete" do
    src = File.read(Rails.root.join("bin/agent-worktree"))
    body = src[/when "sweep-orphan-dbs"(.*?)when "/m, 1]

    refute_nil body, "the sweep-orphan-dbs dispatch moved — re-point this test"
    assert_match(/act = ARGV\.include\?\("--yes"\)/, body, "there is no explicit opt-in flag")
    assert_match(/DRY RUN — nothing was dropped/, body, "the default path does not say it was dry")
    assert_match(/unless act/, body, "the dry path is not gated on the flag")
    # The per-database refusals from the teardown are reused, so even --yes skips
    # a database with live or unreadable connections.
    assert_match(/database_connection_count/, body,
                 "the sweep drops without checking connections — the teardown's refusal must apply")
    assert_match(/left it in place/, body)
  end

  test "the sweep aborts rather than proceeding when the cluster cannot be enumerated" do
    src = File.read(Rails.root.join("bin/agent-worktree"))
    body = src[/def orphan_desk_databases(.*?)^end/m, 1]

    assert_match(/return \[nil, \["postgres/, body,
                 "an unreadable cluster must abort; an empty list would read as 'no orphans' and " \
                 "a later --yes run would drop nothing while reporting success")
  end
end
