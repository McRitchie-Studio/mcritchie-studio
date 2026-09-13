# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

require Rails.root.join("bin/lib/hub_move_diagnosis").to_s

# [unit] The discriminator that decides whether "cannot load such file" is the
# hub primary moving, or the builder's own bug.
#
# The behavioural proof — a real tree moving under a real desk command — lives
# in test/integration/desk_command_survives_hub_move_test.rb. What is guarded
# HERE is the judgement call, because both ways of getting it wrong are costly:
# staying silent on a real move leaves the builder debugging a diff that is
# fine, and crying wolf on a genuinely missing file sends them to re-run a
# command that can never succeed.
class HubMoveDiagnosisTest < ActiveSupport::TestCase
  def setup
    @root = Dir.mktmpdir("hub-move-diagnosis")
    FileUtils.mkdir_p(File.join(@root, "bin", "lib"))
    @tracked = File.join(@root, "bin", "lib", "tracked.rb")
    File.write(@tracked, "# tracked\n")
    git!("init", "--quiet", "--initial-branch=main")
    git!("add", "--all")
    git!("-c", "user.name=Test", "-c", "user.email=test@example.com",
         "-c", "commit.gpgsign=false", "commit", "--quiet", "--message", "seed")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # ── the two ways of being wrong ─────────────────────────────────────────────

  test "a tracked file that is absent right now reads as a moved checkout" do
    FileUtils.rm_f(@tracked)

    message = HubMoveDiagnosis.message_for(load_error(@tracked), root: @root, command: "bin/ship")

    refute_nil message, "a file present in HEAD but gone from the working tree IS the mid-checkout state"
    assert_match(/HUB CHECKOUT MOVED UNDER THIS COMMAND/, message)
    assert_match(/NOT your bug/, message)
    assert_match(/Re-run the command/, message, "a diagnosis without a remedy is just sympathy")
    assert_match(%r{bin/lib/tracked\.rb}, message, "the message must name the file that vanished")
    assert_match(/missing from the working tree but present in HEAD/, message)
  end

  test "a file that was never in HEAD gets NO diagnosis" do
    ghost = File.join(@root, "bin", "lib", "never_existed.rb")

    message = HubMoveDiagnosis.message_for(load_error(ghost), root: @root, command: "bin/ship")

    assert_nil message,
               "a typo'd require was dressed up as an infrastructure hiccup; the builder would re-run a " \
               "command that cannot ever work"
  end

  test "a file that is back on disk reads as rewritten under the running command" do
    # The file loaded late: it was absent when require ran and exists again now.
    message = HubMoveDiagnosis.message_for(load_error(@tracked), root: @root, command: "bin/ship")

    refute_nil message
    assert_match(/EXISTS NOW but was missing/, message,
                 "a file that is back is the STRONGEST evidence of a completed checkout, and the message " \
                 "should say so rather than describe a checkout still in flight")
  end

  test "a path outside the checkout is none of this module's business" do
    assert_nil HubMoveDiagnosis.message_for(load_error("/usr/lib/ruby/somewhere.rb"), root: @root)
  end

  # ── the symlink trap, which silently disabled the whole feature ─────────────
  #
  # REGRESSION (measured 2026-09-13). On macOS /var is a symlink to /private/var.
  # `require_relative` reports the RESOLVED path while a script's own
  # `File.expand_path("..", __dir__)` reports the UNRESOLVED one, so a plain
  # prefix comparison failed and message_for returned nil for every real move.
  # It failed silently — the feature simply never fired — and tmpdirs are
  # exactly where the tests run, so this is the case that must stay covered.
  test "a root and a path that differ only by a resolved symlink still match" do
    link_root = File.join(Dir.mktmpdir("hub-move-link"), "link")
    File.symlink(@root, link_root)
    FileUtils.rm_f(@tracked)

    message = HubMoveDiagnosis.message_for(load_error(@tracked), root: link_root, command: "bin/ship")

    refute_nil message,
               "the path resolved through a symlink and the root did not, so the prefix test failed and " \
               "the diagnosis never fired — the exact shape of the /var vs /private/var bug"
  end

  # ── input handling ──────────────────────────────────────────────────────────

  test "the missing path is read from LoadError#path and from the message alike" do
    with_path = load_error("#{@root}/bin/lib/tracked.rb")
    parsed_only = LoadError.new("cannot load such file -- #{@root}/bin/lib/tracked")

    assert_equal "#{@root}/bin/lib/tracked.rb", HubMoveDiagnosis.missing_path(with_path)
    assert_equal "#{@root}/bin/lib/tracked.rb", HubMoveDiagnosis.missing_path(parsed_only),
                 "a require_relative raising through a wrapper arrives with path nil; the message is the " \
                 "only source left, and it carries no .rb suffix"
  end

  test "a relative or unparseable load error is ignored rather than guessed at" do
    assert_nil HubMoveDiagnosis.missing_path(LoadError.new("cannot load such file -- socket"))
    assert_nil HubMoveDiagnosis.missing_path(LoadError.new("something else entirely"))
  end

  test "the diagnosis never raises, whatever it is handed" do
    assert_nothing_raised do
      HubMoveDiagnosis.message_for(LoadError.new(nil), root: @root)
      HubMoveDiagnosis.message_for(load_error(@tracked), root: "/nonexistent/root")
      HubMoveDiagnosis.message_for(RuntimeError.new("not a load error"), root: @root)
    end
  end

  # ── the evidence that makes it self-diagnosing ──────────────────────────────

  test "the message carries the repo's last HEAD move as checkable evidence" do
    FileUtils.rm_f(@tracked)

    message = HubMoveDiagnosis.message_for(load_error(@tracked), root: @root)

    assert_match(/Last HEAD move:.*seed/, message,
                 "without the reflog line the reader has to take the diagnosis on trust; with it they can " \
                 "see whether the tree moved a second ago or last week")
  end

  test "last_head_move is nil outside a repo rather than an exception" do
    assert_nil HubMoveDiagnosis.last_head_move(Dir.mktmpdir("not-a-repo"))
  end

  private

  # A LoadError shaped like the one require_relative raises: absolute path, no
  # extension, with #path populated.
  def load_error(path)
    stripped = path.to_s.sub(/\.rb\z/, "")
    error = LoadError.new("cannot load such file -- #{stripped}")
    error.instance_variable_set(:@path, stripped)
    def error.path = @path
    error
  end

  def git!(*args)
    out, status = Open3.capture2e("git", "-C", @root, *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out
  end
end
