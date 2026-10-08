# frozen_string_literal: true

# Tests for bin/dream, the dream sequence printer.
#   ruby -Itest test/lib/dream_cli_test.rb
#
#   [unit] each command against a throwaway bank: what prints, where, and the exit code.

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "stringio"

load File.expand_path("../../bin/dream", __dir__)

class DreamCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/dream", __dir__)

  def dream(question, extra = "")
    "---\nquestion: \"#{question}\"\nanswer: \"An answer.\"\nwhy: \"A reason.\"\nstatus: approved\n#{extra}---\n"
  end

  def setup
    @dir = Dir.mktmpdir("dream-cli")
    write("platform/universal.md", dream("A universal question?"))
    write("carl/review.md", dream("A review question?", "soul: carl\n"))
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write(relative, text)
    path = File.join(@dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def run_bin(*argv)
    out = StringIO.new
    err = StringIO.new
    code = DreamCli.new(env: { "DREAM_BANK_DIR" => @dir }, out: out, err: err).run(argv)
    [ out.string, err.string, code ]
  end

  def test_unit_the_script_exits_with_the_command_code
    out, err, status = Open3.capture3({ "DREAM_BANK_DIR" => @dir }, RbConfig.ruby, BIN, "nobody")

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_includes err, "is not a soul"
  end

  def test_unit_a_soul_prints_its_sequence_and_not_the_platform_one
    out, err, code = run_bin("carl", "--task", "some-task")

    assert_equal 0, code
    assert_equal "", err
    assert_includes out, "## Carl's dream sequence · task some-task"
    assert_includes out, "**Q: A review question?** (`review`)"
    refute_includes out, "A universal question?"
  end

  def test_unit_a_soul_is_named_by_any_of_its_spellings
    write("turf-monster/contest.md", dream("A contest question?", "soul: turf-monster\n"))

    assert_includes run_bin("turf_monster").first, "## Turf Monster's dream sequence"
    assert_includes run_bin("Turf-Monster").first, "A contest question?"
  end

  def test_unit_a_soul_with_no_dreams_is_pointed_at_its_role_page
    out, _err, code = run_bin("jasper")

    assert_equal 0, code
    assert_equal "Jasper has no approved dreams. Role page: `docs/agents/agents/jasper/role.md`.\n", out
  end

  def test_unit_an_unknown_soul_is_refused_with_the_roster
    out, err, code = run_bin("nobody")

    assert_equal 1, code
    assert_equal "", out
    assert_match(/\Adream: `nobody` is not a soul\. Souls: xan, avi, carl,/, err)
  end

  def test_unit_platform_prints_the_session_start_sequence
    out, _err, code = run_bin("platform")

    assert_equal 0, code
    assert_includes out, "## Dreams"
    assert_includes out, "A universal question?"
    assert_includes out, "### Helper agents"
    refute_includes out, "A review question?"
  end

  def test_unit_index_writes_then_checks_and_refuses_a_stale_file
    path = File.join(@dir, "INDEX.md")

    _out, err, code = run_bin("index", "--check")
    assert_equal 1, code
    assert_includes err, "is stale. Run `bin/dream index --write`."
    refute File.exist?(path), "--check writes nothing"

    assert_equal 0, run_bin("index", "--write").last
    assert_equal run_bin("index").first, File.read(path)
    assert_equal 0, run_bin("index", "--check").last

    write("carl/second.md", dream("A second question?", "soul: carl\n"))
    assert_equal 1, run_bin("index", "--check").last
  end

  def test_unit_help_and_bad_arguments_print_usage_and_write_nothing
    out, _err, code = run_bin("index", "--write", "--help")
    assert_equal 0, code
    assert_includes out, "bin/dream <soul> [--task <slug>]"
    refute File.exist?(File.join(@dir, "INDEX.md")), "--help is inert"

    [ [], %w[index --rewrite], %w[carl --task], %w[carl extra], %w[platform extra] ].each do |argv|
      out, err, code = run_bin(*argv)
      assert_equal 2, code, argv.inspect
      assert_equal "", out
      assert_includes err, "bin/dream <soul> [--task <slug>]"
    end
  end
end
