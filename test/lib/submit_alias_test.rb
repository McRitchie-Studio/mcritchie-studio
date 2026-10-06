# frozen_string_literal: true

# [unit] bin/ship and bin/ship-wait are the old names of bin/submit and
# bin/submit-wait, kept as aliases for one release. Running sessions call them
# through the fixed-path tooling, so each alias must print one rename line and
# exec the new script with the WHOLE argument line, untouched.
#
# Each alias is copied into a scratch bin/ beside a stub that records its argv, so
# the test reads exactly what the alias handed over without running a real
# handoff. A mutant alias that drops an argument is run through the same check, so
# the assertion is shown to bite.
#
# Run directly:
#   ruby -Itest test/lib/submit_alias_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class SubmitAliasTest < Minitest::Test
  BIN = File.expand_path("../../bin", __dir__)
  ALIASES = { "ship" => "submit", "ship-wait" => "submit-wait" }.freeze
  # Spaces, a quote and a glob: the forms a lossy `$*` or an unquoted `$@` mangles.
  ARGS = ["some-task", "--launch", "-m", "Fix the nav bar's * width", ""].freeze

  # Copies `source` into a scratch bin/ as `old`, beside a `new` stub that writes
  # its argv, one per line, to a file. Returns [stdout, stderr, status, argv].
  def run_alias(old, new, source: File.read(File.join(BIN, old)))
    Dir.mktmpdir("submit-alias") do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      record = File.join(dir, "argv")
      File.write(File.join(bin, old), source)
      File.write(File.join(bin, new), <<~SH)
        #!/bin/sh
        for arg in "$@"; do printf '%s\\n' "$arg"; done > "#{record}"
        echo "stub #{new} ran"
      SH
      FileUtils.chmod("+x", [File.join(bin, old), File.join(bin, new)])

      out, err, status = Open3.capture3(File.join(bin, old), *ARGS)
      argv = File.exist?(record) ? File.read(record).split("\n", -1)[0...-1] : nil
      [out, err, status, argv]
    end
  end

  def test_each_alias_prints_the_rename_note_and_execs_the_new_name_with_the_same_arguments
    ALIASES.each do |old, new|
      out, err, status, argv = run_alias(old, new)

      assert status.success?, "bin/#{old} failed: #{err}"
      assert_equal "stub #{new} ran\n", out, "bin/#{old} must exec bin/#{new}, which owns stdout"
      assert_match(%r{\Abin/#{Regexp.escape(old)} is renamed bin/#{Regexp.escape(new)}; running \S+/#{Regexp.escape(new)} },
                   err, "bin/#{old} must print one rename line on stderr")
      assert_equal 1, err.lines.size, "the note is one line"
      assert_equal ARGS, argv, "bin/#{old} must hand bin/#{new} the whole argument line, untouched"
    end
  end

  # Control: an alias that forwards `$*` instead of "$@" splits the commit message
  # and drops the empty argument. The check above must see it.
  def test_the_argument_check_bites_a_lossy_alias
    lossy = File.read(File.join(BIN, "ship")).sub('"$@"', "$*")
    refute_equal File.read(File.join(BIN, "ship")), lossy, "the mutant must differ from the alias"

    _out, _err, status, argv = run_alias("ship", "submit", source: lossy)

    assert status.success?
    refute_equal ARGS, argv, "a lossy alias passed the argument check, so the check proves nothing"
  end

  # The real tree: the alias reaches the real bin/submit, whose parser answers --help.
  def test_the_real_alias_reaches_the_real_submit
    out, err, status = Open3.capture3(File.join(BIN, "ship"), "--help")

    assert status.success?, err
    assert_match(%r{Usage: \S+/bin/submit <task-slug>}, out)
    assert_match(%r{\Abin/ship is renamed bin/submit}, err)
  end
end
