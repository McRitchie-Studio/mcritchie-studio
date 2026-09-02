# frozen_string_literal: true

# [unit] ScratchBackup — the two properties that make a scratchpad backup safe.
#
# THE FAILURE UNDER TEST IS INVISIBLE BY CONSTRUCTION, which is why it needs a
# test rather than a convention. Two agents saving a pristine `manifest.good` into
# the session's shared scratchpad write SEQUENTIALLY: no truncation, no NUL hole,
# no corrupt file — the second copy simply replaces the first, and the first agent
# discovers it by restoring and getting someone else's code. There is nothing on
# disk to grep for. (Contrast the sibling incident one directory up, where a
# `>` against a held fd left a 2,586-byte hole that `file` reports as `data`.)
#
# So the assertions below are about the two things that CAN be checked:
#
#   NAMESPACED  — two owners saving the SAME path get different entries, and each
#                 restores its own content. The collision cannot happen.
#   VERIFIED    — when the namespace is defeated anyway (a hand-passed --owner, a
#                 shared root, a future harness that reuses ids), restore REFUSES
#                 on the receipt mismatch instead of handing over the wrong file.
#
# Each refusal test is paired with a control that SUCCEEDS on the same fixture,
# because a refusal that fires unconditionally is indistinguishable from a working
# guard right up until it blocks the legitimate restore too.
#
#   ruby -Itest test/lib/scratch_backup_test.rb

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../../bin/lib/scratch_backup"

class ScratchBackupTest < Minitest::Test
  PRISTINE = "puts :pristine\n"
  SOMEONE_ELSE = "puts :someone_elses_file\n"

  def setup
    @dir = Dir.mktmpdir("scratch-backup-test")
    @root = File.join(@dir, "root")
    @source = File.join(@dir, "work", "manifest.good")
    FileUtils.mkdir_p(File.dirname(@source))
    File.write(@source, PRISTINE)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def save(owner: "avi-task", source: @source, **kwargs)
    ScratchBackup.save(source: source, root: @root, owner: owner, **kwargs)
  end

  def blob(owner: "avi-task", source: @source)
    ScratchBackup.blob_path(root: @root, owner: owner, source: source)
  end

  # --- property 1: namespaced by its writer ---------------------------------

  # THE HEADLINE. Two agents, one shared root, the same source path, different
  # content — the exact shape of the un-namespaced `backup/manifest.good`. Each
  # gets its own file back.
  def test_two_owners_saving_the_same_path_do_not_overwrite_each_other
    save(owner: "carl-task")

    File.write(@source, SOMEONE_ELSE)
    save(owner: "steffon-task")

    ScratchBackup.restore(source: @source, root: @root, owner: "carl-task")
    assert_equal PRISTINE, File.read(@source), "carl restored steffon's file"

    ScratchBackup.restore(source: @source, root: @root, owner: "steffon-task")
    assert_equal SOMEONE_ELSE, File.read(@source), "steffon restored carl's file"
  end

  # One owner, two repos, the same basename — `manifest.good` is not a rare name.
  # The entry carries a digest of the ABSOLUTE path, so these are two entries.
  def test_one_owner_does_not_collide_with_itself_across_directories
    other = File.join(@dir, "other-repo", "manifest.good")
    FileUtils.mkdir_p(File.dirname(other))
    File.write(other, SOMEONE_ELSE)

    save
    save(source: other)

    refute_equal blob, blob(source: other)
    assert_equal PRISTINE, File.binread(blob)
    assert_equal SOMEONE_ELSE, File.binread(blob(source: other))
  end

  # The basename stays on the front for legibility; the digest is what discriminates.
  def test_entry_name_is_basename_plus_a_path_digest
    name = ScratchBackup.entry_name("/a/b/manifest.good")

    assert_match(/\Amanifest\.good-[0-9a-f]{12}\z/, name)
    refute_equal name, ScratchBackup.entry_name("/c/d/manifest.good")
  end

  def test_every_entry_sits_under_its_owner
    assert_equal File.join(@root, "avi-task", "backup"),
                 ScratchBackup.entry_dir(root: @root, owner: "avi-task")
  end

  # --- property 2: verified at restore --------------------------------------

  # THE TEST THE TASK WAS FILED FOR. Simulate the collision directly: another
  # writer lands on this exact blob path (which is what an un-namespaced backup
  # IS). The restore must refuse, and must leave the working file alone.
  def test_a_mismatched_restore_refuses_rather_than_succeeding
    save
    File.write(@source, "puts :mutated\n")
    File.binwrite(blob, SOMEONE_ELSE) # the colliding agent

    error = assert_raises(ScratchBackup::Refusal) do
      ScratchBackup.restore(source: @source, root: @root, owner: "avi-task")
    end

    assert_match(/backup content changed since it was saved/, error.message)
    assert_equal "puts :mutated\n", File.read(@source),
                 "the refusal must not half-restore — the working file is untouched"
  end

  # THE CONTROL for the test above, on the same fixture minus the collision. A
  # guard that refuses every restore would pass that test and be useless.
  def test_an_untouched_backup_restores
    save
    File.write(@source, "puts :mutated\n")

    ScratchBackup.restore(source: @source, root: @root, owner: "avi-task")

    assert_equal PRISTINE, File.read(@source)
  end

  def test_verify_reports_ok_missing_and_mismatch
    assert_equal :missing, ScratchBackup.verify(source: @source, root: @root, owner: "avi-task").first

    save
    assert_equal :ok, ScratchBackup.verify(source: @source, root: @root, owner: "avi-task").first

    File.binwrite(blob, SOMEONE_ELSE)
    status, detail = ScratchBackup.verify(source: @source, root: @root, owner: "avi-task")
    assert_equal :mismatch, status
    assert_match(/receipt [0-9a-f]{64}, on disk [0-9a-f]{64}/, detail)
  end

  # A receipt whose blob was deleted is missing, not ok — the one case where "no
  # file" and "nothing recorded" have to be told apart, because only one of them
  # means someone reached into your namespace.
  def test_verify_reports_missing_when_the_blob_is_gone_but_the_receipt_remains
    save
    File.delete(blob)

    status, detail = ScratchBackup.verify(source: @source, root: @root, owner: "avi-task")

    assert_equal :missing, status
    assert_match(/its blob is gone/, detail)
  end

  # Fail closed on a receipt that does not describe the file being asked for. It
  # takes a hand-edit or a digest collision to reach, and both mean the namespace
  # is not saying what it appears to say.
  def test_verify_refuses_a_receipt_that_records_a_different_source
    save
    path = ScratchBackup.receipt_path(root: @root, owner: "avi-task", source: @source)
    receipt = JSON.parse(File.read(path))
    File.write(path, JSON.generate(receipt.merge("source" => "/somewhere/else")))

    status, = ScratchBackup.verify(source: @source, root: @root, owner: "avi-task")

    assert_equal :moved, status
    assert_raises(ScratchBackup::Refusal) do
      ScratchBackup.restore(source: @source, root: @root, owner: "avi-task")
    end
  end

  # --- save: the self-collision ---------------------------------------------

  # The mutation-testing footgun: save pristine, mutate, absent-mindedly re-run
  # save, and the only copy of the file you were about to restore is gone.
  def test_save_refuses_to_overwrite_a_backup_of_different_content
    save
    File.write(@source, SOMEONE_ELSE)

    error = assert_raises(ScratchBackup::Refusal) { save }

    assert_match(/already has a backup of DIFFERENT content/, error.message)
    assert_equal PRISTINE, File.binread(blob), "the refusal must leave the restore point intact"
  end

  # CONTROL, two halves: an idempotent re-save of identical content is not a
  # collision and must not need --force; and --force is a real escape hatch.
  def test_resaving_identical_content_is_allowed_and_force_overwrites
    save
    save # identical — no raise

    File.write(@source, SOMEONE_ELSE)
    save(force: true)

    assert_equal SOMEONE_ELSE, File.binread(blob)
  end

  # --- receipt --------------------------------------------------------------

  def test_save_records_a_receipt_beside_the_blob
    receipt = save(writer: "claude:abc:123")
    on_disk = JSON.parse(File.read(ScratchBackup.receipt_path(root: @root, owner: "avi-task", source: @source)))

    assert_equal receipt, on_disk
    assert_equal Digest::SHA256.hexdigest(PRISTINE), on_disk["sha256"]
    assert_equal File.expand_path(@source), on_disk["source"]
    assert_equal PRISTINE.bytesize, on_disk["bytes"]
    assert_equal "avi-task", on_disk["owner"]
    assert_equal "claude:abc:123", on_disk["writer"]
    assert_equal ScratchBackup::RECEIPT_VERSION, on_disk["version"]
  end

  def test_restore_puts_the_mode_back
    File.chmod(0o755, @source)
    save
    File.chmod(0o644, @source)

    ScratchBackup.restore(source: @source, root: @root, owner: "avi-task")

    assert_equal "755", format("%o", File.stat(@source).mode & 0o777)
  end

  def test_save_refuses_a_source_that_is_not_a_file
    error = assert_raises(ScratchBackup::Refusal) { save(source: File.join(@dir, "nope")) }

    assert_match(/no such file to back up/, error.message)
  end

  # --- listing --------------------------------------------------------------

  def test_entries_reports_each_entry_with_its_status
    other = File.join(@dir, "work", "test.good")
    File.write(other, SOMEONE_ELSE)
    save
    save(source: other)
    File.binwrite(blob(source: other), "tampered\n")

    listed = ScratchBackup.entries(root: @root, owner: "avi-task")

    assert_equal [File.expand_path(@source), File.expand_path(other)],
                 listed.map { |entry| entry["receipt"]["source"] }
    assert_equal [:ok, :mismatch], listed.map { |entry| entry["status"] }
  end

  def test_entries_is_empty_for_an_owner_with_no_namespace
    assert_empty ScratchBackup.entries(root: @root, owner: "nobody")
  end

  # --- owner resolution -----------------------------------------------------

  # FAIL CLOSED. An owner-less default would be a shared directory, and a shared
  # directory is the entire defect.
  def test_resolve_owner_refuses_when_nothing_names_one
    error = assert_raises(ScratchBackup::Refusal) do
      ScratchBackup.resolve_owner(env: {}, dir: @dir)
    end

    assert_match(/cannot resolve an owner/, error.message)
  end

  def test_resolve_owner_prefers_explicit_then_env_then_context_then_session
    context_dir = File.join(@dir, "desk", "nested")
    FileUtils.mkdir_p(context_dir)
    File.write(File.join(@dir, "desk", ".agent-context.json"),
               JSON.generate({ "task_slug" => "from-context" }))

    session_env = { "CLAUDE_CODE_SESSION_ID" => "sess-1" }
    env = session_env.merge("SCRATCH_BACKUP_OWNER" => "from-env")

    assert_equal "from-flag", ScratchBackup.resolve_owner(explicit: "from-flag", env: env, dir: context_dir)
    assert_equal "from-env", ScratchBackup.resolve_owner(env: env, dir: context_dir)
    assert_equal "from-context", ScratchBackup.resolve_owner(env: session_env, dir: context_dir)
    assert_equal "claude-sess-1", ScratchBackup.resolve_owner(env: session_env, dir: @dir)
  end

  # An owner is ONE path segment. `../` in a slug would climb out of the very
  # namespace the slug exists to create, so separators are collapsed, not honored.
  def test_owner_cannot_escape_its_namespace
    assert_equal "feat-foo", ScratchBackup.sanitize_owner("feat/foo")
    assert_equal "evil", ScratchBackup.sanitize_owner("../evil")
    assert_nil ScratchBackup.sanitize_owner("..")
    assert_nil ScratchBackup.sanitize_owner("   ")

    dir = ScratchBackup.entry_dir(root: @root, owner: ScratchBackup.sanitize_owner("../evil"))
    assert dir.start_with?(@root), "an owner must never resolve outside the root"
  end

  # --- root resolution ------------------------------------------------------

  def test_resolve_root_prefers_explicit_then_env_then_discovery_then_tmp
    scratchpad = File.join(@dir, "tmpbase", "claude-501", "-Users-alex-projects", "sess-9", "scratchpad")
    FileUtils.mkdir_p(scratchpad)
    env = { "CLAUDE_CODE_SESSION_ID" => "sess-9",
            "SCRATCH_BACKUP_TMPDIR" => File.join(@dir, "tmpbase"),
            "SCRATCH_BACKUP_ROOT" => File.join(@dir, "from-env") }

    assert_equal File.join(@dir, "from-flag"),
                 ScratchBackup.resolve_root(explicit: File.join(@dir, "from-flag"), env: env)
    assert_equal File.join(@dir, "from-env"), ScratchBackup.resolve_root(env: env)
    assert_equal scratchpad, ScratchBackup.resolve_root(env: env.reject { |key, _| key == "SCRATCH_BACKUP_ROOT" })
  end

  # Discovery is harness-shaped and WILL rot. When it does it must MISS, not match
  # something else — the fallback is still namespaced by owner, so rot costs a
  # location, never the safety property.
  def test_discovery_misses_rather_than_guessing_when_the_session_is_unknown
    assert_nil ScratchBackup.discovered_scratchpad({})
    assert_nil ScratchBackup.discovered_scratchpad("CLAUDE_CODE_SESSION_ID" => "no-such-session",
                                                  "SCRATCH_BACKUP_TMPDIR" => @dir)

    root = ScratchBackup.resolve_root(env: { "SCRATCH_BACKUP_TMPDIR" => @dir })
    assert_equal File.join(root, "avi-task", "backup"),
                 ScratchBackup.entry_dir(root: root, owner: "avi-task")
  end

  # --- atomicity ------------------------------------------------------------

  # A rename means a reader sees the whole old file or the whole new one. It also
  # removes the failure mode the sibling log incident was made of: a truncating
  # open against a file another process still holds an fd on.
  def test_writes_leave_no_temp_files_behind
    save
    File.write(@source, SOMEONE_ELSE)
    save(force: true)

    leftovers = Dir.glob(File.join(ScratchBackup.entry_dir(root: @root, owner: "avi-task"), ".*tmp*"))

    assert_empty leftovers
    assert_equal SOMEONE_ELSE, File.binread(blob)
  end
end
