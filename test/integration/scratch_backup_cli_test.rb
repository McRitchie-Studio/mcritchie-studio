# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"

# [integration] bin/scratch-backup driven through the REAL script, as two separate
# OS processes, across a real filesystem — because that is what the defect is made
# of. A collided backup is not a bug inside one process's memory; it is two agents,
# started minutes apart, arriving at the same path.
#
# WHY THE PROBES RUN FOR REAL HERE, unlike test/integration/agent_worktree_argv_guard_test.rb.
# That file must never execute its subject, because a regressed guard would ALLOCATE
# a desk during the probe. This script's entire blast radius is `--root`, and every
# test below points it at a Dir.mktmpdir. So the guard is proven the strong way — the
# real binary, a real exit status, and an assertion that the temp root is still
# EMPTY afterwards — instead of by reading the source.
#
# The three things this tier can prove that the unit tier cannot:
#
#   1. TWO PROCESSES, one shared root, the same source path. The unit tier calls one
#      module twice; this runs the actual binary twice, the way it will be used.
#   2. THE EXIT STATUS IS THE VERDICT. `verify` returns 3 on a tampered backup and 0
#      on an intact one, so a shell script can gate on it. A refusal that only prints
#      is not a refusal a caller can act on.
#   3. THE REFUSALS WRITE NOTHING — asserted by measuring the root, not by trusting
#      the message.
#
#   bin/rails test test/integration/scratch_backup_cli_test.rb
class ScratchBackupCliTest < ActionDispatch::IntegrationTest
  SCRIPT = Rails.root.join("bin", "scratch-backup").to_s

  PRISTINE = "puts :pristine\n"
  SOMEONE_ELSE = "puts :someone_elses_file\n"

  setup do
    @dir = Dir.mktmpdir("scratch-backup-cli")
    @root = File.join(@dir, "root")
    @source = File.join(@dir, "manifest.good")
    File.write(@source, PRISTINE)
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # Runs the real script with an environment that names NO session, so nothing in
  # the harness this suite happens to run under can resolve an owner behind the
  # test's back and make a refusal look like a pass.
  def run_cli(*args, env: {})
    clean = { "CLAUDE_CODE_SESSION_ID" => nil, "CODEX_THREAD_ID" => nil,
              "SCRATCH_BACKUP_OWNER" => nil, "SCRATCH_BACKUP_ROOT" => nil }
    Open3.capture3(clean.merge(env), SCRIPT, *args, chdir: @dir)
  end

  def save(*extra, owner:)
    run_cli("save", @source, "--root", @root, "--owner", owner, *extra)
  end

# The one blob in an owner's namespace, located rather than guessed, so a change to
# the entry-naming scheme fails here loudly instead of silently matching nothing.
def blob_for(owner)
  found = Dir.glob(File.join(@root, owner, "backup", "manifest.good-*"))
             .reject { |path| path.end_with?(".json") }
  assert_equal 1, found.length, "expected exactly one blob for #{owner}, got #{found.inspect}"
  found.first
end

  def files_under_root
    return [] unless File.directory?(@root)

    Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
  end

  # --- the collision, end to end --------------------------------------------

  # THE HEADLINE, as two processes. Both agents back up the same path into the same
  # root; each restores its own file. Un-namespaced, the second `cp` would have
  # silently replaced the first and carl would restore steffon's code.
  test "two agents backing up the same path each restore their own file" do
    _, _, status = save(owner: "carl-task")
    assert_predicate status, :success?

    File.write(@source, SOMEONE_ELSE)
    _, _, status = save(owner: "steffon-task")
    assert_predicate status, :success?

    _, _, status = run_cli("restore", @source, "--root", @root, "--owner", "carl-task")
    assert_predicate status, :success?
    assert_equal PRISTINE, File.read(@source), "carl restored steffon's file"

    _, _, status = run_cli("restore", @source, "--root", @root, "--owner", "steffon-task")
    assert_predicate status, :success?
    assert_equal SOMEONE_ELSE, File.read(@source), "steffon restored carl's file"
  end

  # WITH THE NAMESPACE DELIBERATELY DEFEATED — both agents forced onto one owner,
  # which is what today's shared `backup/` is. The second save REFUSES instead of
  # destroying the first agent's restore point, and says whose it was.
  test "a second agent on the same owner refuses rather than replacing the backup" do
    save(owner: "shared")

    File.write(@source, SOMEONE_ELSE)
    _, err, status = save(owner: "shared")

    refute_predicate status, :success?
    assert_match(/already has a backup of DIFFERENT content/, err)

    File.write(@source, "puts :mutated\n")
    _, _, status = run_cli("restore", @source, "--root", @root, "--owner", "shared")
    assert_predicate status, :success?
    assert_equal PRISTINE, File.read(@source), "the first agent's restore point survived"
  end

  # AND IF IT IS DEFEATED ANYWAY — a writer that never went through this tool at
  # all, which is the honest worst case while `cp` still exists. The receipt catches
  # it; the working file is left alone.
  test "restore refuses a backup another writer overwrote and touches nothing" do
    save(owner: "avi-task")
    blob = blob_for("avi-task")
    File.binwrite(blob, SOMEONE_ELSE)
    File.write(@source, "puts :mutated\n")

    _, err, status = run_cli("restore", @source, "--root", @root, "--owner", "avi-task")

    refute_predicate status, :success?
    assert_match(/refusing to restore/, err)
    assert_match(/backup content changed since it was saved/, err)
    assert_equal "puts :mutated\n", File.read(@source)
  end

  # --- the exit status is the verdict ---------------------------------------

  test "verify exits 0 on an intact backup and 3 on a tampered one" do
    save(owner: "avi-task")

    out, _, status = run_cli("verify", @source, "--root", @root, "--owner", "avi-task")
    assert_equal 0, status.exitstatus
    assert_match(/\Aok\s/, out)

    blob = blob_for("avi-task")
    File.binwrite(blob, SOMEONE_ELSE)

    _, err, status = run_cli("verify", @source, "--root", @root, "--owner", "avi-task")
    assert_equal 3, status.exitstatus, "a caller must be able to gate a shell script on this"
    assert_match(/MISMATCH/, err)
  end

  test "list reports each entry with its status" do
    save(owner: "avi-task")
    out, _, status = run_cli("list", "--root", @root, "--owner", "avi-task")

    assert_predicate status, :success?
    assert_match(/^ok\s+[0-9a-f]{12}\s/, out)
    assert_match(/manifest\.good/, out)
  end

  # --- the guard, proven by measuring the root ------------------------------

  # `--help` is the probe every operator tries first. On this ecosystem it has
  # already rolled a docs ledger, taken a shift lease and promoted a release, so it
  # is asserted here by MEASUREMENT: the root is still empty afterwards.
  test "help backs up nothing, exits 1, and leaves the root empty" do
    out, err, status = run_cli("save", @source, "--root", @root, "--owner", "avi-task", "--help")

    assert_equal 1, status.exitstatus, "verify makes exit 0 an assertion, so help must not use it"
    assert_match(/BACKS UP NOTHING, RESTORES NOTHING/, err)
    assert_empty out
    assert_empty files_under_root
  end

  test "an unrecognized argument refuses and writes nothing" do
    _, err, status = run_cli("save", @source, "--root", @root, "--owner", "avi-task", "--overwrite")

    assert_equal 2, status.exitstatus
    assert_match(/unrecognized argument "--overwrite"/, err)
    assert_match(/nothing was backed up, restored or overwritten/, err)
    assert_empty files_under_root
  end

  # The refusal must blame the COMMAND, not the perfectly valid --root beside it —
  # which is what an empty flag dictionary would have done, sending the reader to
  # hunt for a typo in the option.
  test "an unknown command refuses and writes nothing" do
    _, err, status = run_cli("backup", @source, "--root", @root)

    assert_equal 1, status.exitstatus
    assert_match(/unknown command "backup"/, err)
    assert_empty files_under_root
  end

  test "a save with no file, and a list with one, both refuse" do
    _, err, status = run_cli("save", "--root", @root, "--owner", "avi-task")
    assert_equal 1, status.exitstatus
    assert_match(/expects exactly one file/, err)

    _, err, status = run_cli("list", @source, "--root", @root, "--owner", "avi-task")
    assert_equal 1, status.exitstatus
    assert_match(/takes no file argument/, err)

    assert_empty files_under_root
  end

  # FAIL CLOSED. With no --owner, no env and no .agent-context.json above the cwd,
  # the tool has no namespace to write into — and a default namespace would be a
  # shared directory, which is the defect. It refuses.
  test "an unresolvable owner refuses rather than defaulting to a shared directory" do
    _, err, status = run_cli("save", @source, "--root", @root)

    assert_equal 1, status.exitstatus
    assert_match(/cannot resolve an owner/, err)
    assert_empty files_under_root
  end

  # CONTROL for the test above: the same line, with the one missing fact supplied
  # by the desk marker the worktree already carries. A guard that refused every
  # save would pass that test and be useless.
  test "the desk's agent-context task_slug supplies the owner" do
    File.write(File.join(@dir, ".agent-context.json"), JSON.generate({ "task_slug" => "from-the-desk" }))

    _, _, status = run_cli("save", @source, "--root", @root)

    assert_predicate status, :success?
    assert_path_exists File.join(@root, "from-the-desk", "backup")
  end
end
