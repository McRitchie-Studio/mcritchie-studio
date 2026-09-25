# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/desk_claim"
require_relative "../support/fake_desk"

# [unit] THE DESK IS THE BUILD CLAIM — the one refusal rule, driven over plain data.
# DeskClaim.blocking reads no clock, no process table and no disk: the desks and the
# dirtiness answer are inputs, so every case is a row here.
class DeskClaimTest < Minitest::Test
  SLUG = "probe-task"
  ME = "sess-me"
  OTHER = "sess-other"

  def desk(session: OTHER, grade: :live, slug: SLUG, parent: nil, worktree: "/desks/#{session}")
    { path: "#{worktree}/.agent-context.json", worktree: worktree, task_slug: slug, grade: grade,
      detail: { session_id: session, parent_session_id: parent } }
  end

  def blocking(desks, dirty: true, session: ME)
    DeskClaim.blocking(SLUG, desks: desks, session: session, dirty: ->(_) { dirty })
  end

  def test_unit_a_foreign_live_dirty_desk_blocks
    assert_equal 1, blocking([desk]).length
  end

  def test_unit_a_foreign_unverifiable_desk_counts_as_live
    assert_equal 1, blocking([desk(grade: :unverifiable)]).length
  end

  def test_unit_a_clean_foreign_desk_does_not_block
    assert_empty blocking([desk], dirty: false)
  end

  # nil is "git could not answer" — on the one path that can lose work it blocks.
  def test_unit_an_unreadable_desk_blocks
    assert_equal 1, blocking([desk], dirty: nil).length
  end

  def test_unit_the_movers_own_desk_does_not_block
    assert_empty blocking([desk(session: ME)])
  end

  def test_unit_a_desk_naming_the_mover_as_parent_does_not_block
    assert_empty blocking([desk(parent: ME)])
  end

  def test_unit_a_desk_whose_holder_is_gone_does_not_block
    %i[dead recycled unclaimed malformed].each do |grade|
      assert_empty blocking([desk(grade: grade)]), "grade #{grade} names no live holder"
    end
  end

  def test_unit_a_desk_bound_to_another_task_does_not_block
    assert_empty blocking([desk(slug: "other-task")])
  end

  # A mover with no session cannot own any desk, so every live dirty desk is foreign.
  def test_unit_a_sessionless_mover_owns_no_desk
    assert_equal 1, blocking([desk(session: ME)], session: nil).length
  end

  def test_unit_the_refusal_names_the_desk_and_both_commands
    lines = DeskClaim.refusal(SLUG, [desk], steal_command: "bin/task move #{SLUG} building --steal",
                                            retry_command: "bin/task move #{SLUG} building")
    text = lines.join("\n")

    assert_includes text, "/desks/#{OTHER}"
    assert_includes text, "uncommitted changes"
    assert_includes text, "re-run: bin/task move #{SLUG} building"
    assert_includes text, "--steal"
  end

  # [integration] The disk reader, against a real git worktree.
  def test_integration_dirty_reads_git_status
    Dir.mktmpdir do |root|
      clean = FakeDesk.build(root, task_slug: "a", session: OTHER, dirty: false)
      dirty = FakeDesk.build(root, task_slug: "b", session: OTHER, dirty: true)

      assert_equal false, DeskClaim.dirty?(clean), "the bound context file is ignored, not dirt"
      assert_equal true, DeskClaim.dirty?(dirty)
      assert_nil DeskClaim.dirty?(File.join(root, "not-a-repo"))
    end
  end

  def test_integration_blocking_on_disk_finds_the_foreign_dirty_desk
    Dir.mktmpdir do |root|
      path = FakeDesk.build(root, task_slug: SLUG, session: OTHER, dirty: true)
      FakeDesk.build(root, task_slug: SLUG, session: ME, dirty: true, repo: "turf-monster")

      found = DeskClaim.blocking_on_disk(SLUG, session: ME, projects_dir: root)

      assert_equal [path], found.map { |d| DeskClaim.path(d) }
    end
  end

  # --- the archive holder guard: a dirty desk bound to the task -------------

  def dirty_bound(desks, dirty: true)
    DeskClaim.dirty_bound(SLUG, desks: desks, dirty: ->(_) { dirty })
  end

  def test_unit_archive_refuses_a_dirty_bound_desk_whoever_holds_it
    [desk, desk(session: ME), desk(grade: :dead)].each do |d|
      assert_equal 1, dirty_bound([d]).length, "a dirty desk loses work whatever its holder's state"
    end
  end

  def test_unit_archive_refuses_an_unreadable_desk
    assert_equal 1, dirty_bound([desk], dirty: nil).length
  end

  def test_unit_archive_passes_a_clean_desk_or_none
    assert_empty dirty_bound([desk], dirty: false)
    assert_empty dirty_bound([])
    assert_empty dirty_bound([desk(slug: "other-task")])
  end

  def test_unit_the_archive_refusal_names_the_desk_and_the_override
    lines = DeskClaim.archive_refusal(SLUG, [desk], force_command: "bin/task move #{SLUG} archived --force")
    text = lines.join("\n")

    assert_includes text, "/desks/#{OTHER}"
    assert_includes text, "--force"
  end

  def test_integration_dirty_bound_on_disk_finds_only_the_dirty_desk
    Dir.mktmpdir do |root|
      path = FakeDesk.build(root, task_slug: SLUG, session: ME, dirty: true)
      FakeDesk.build(root, task_slug: SLUG, session: OTHER, dirty: false, repo: "turf-monster")

      found = DeskClaim.dirty_bound_on_disk(SLUG, projects_dir: root)

      assert_equal [path], found.map { |d| DeskClaim.path(d) }
    end
  end
end
