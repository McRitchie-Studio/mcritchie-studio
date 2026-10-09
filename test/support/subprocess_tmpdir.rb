# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# SubprocessTmpdir — one temp directory per TEST, for the subprocesses that test spawns.
#
# WHY: a script under test that writes to a path FIXED under Dir.tmpdir shares that
# file with every other process on the machine. bin/release builds a gem at
# File.join(Dir.tmpdir, "release-<repo>-<version>.gem"), and the suite runs in forked
# workers: two tests building studio-engine 0.96.0 at the same moment write ONE file,
# and each reads whichever build landed last. The test asserting a checksum refusal
# then sees its control's matching gem, and passes straight through to the push.
#
# Dir.tmpdir reads TMPDIR on every call, so a child handed its own TMPDIR resolves
# every such path inside a directory no other test names:
#
#   include SubprocessTmpdir
#   Open3.capture3(env.merge("TMPDIR" => subprocess_tmpdir), "ruby", "-e", script)
#
# One directory per test, not per spawn: a test that spawns twice (a re-run, a
# retried attempt) finds what its first child left. Created on first use, so a test
# that spawns nothing makes nothing, and removed with the test.
module SubprocessTmpdir
  def subprocess_tmpdir
    @subprocess_tmpdir ||= Dir.mktmpdir("subprocess-tmp")
  end

  def after_teardown
    super
  ensure
    FileUtils.remove_entry(@subprocess_tmpdir) if @subprocess_tmpdir && File.exist?(@subprocess_tmpdir)
    @subprocess_tmpdir = nil
  end
end
