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

  FIXTURES = File.expand_path("../fixtures/dreams", __dir__)
  PAYMENT = { "stage" => "building", "title" => "Settle Payout Once",
              "metadata" => { "devops" => { "repositories" => [ "turf-monster" ], "risk_tags" => [ "money" ],
                                            "shape" => "backend",
                                            "acceptance" => [ "A retried payout pays one settlement" ] } } }.freeze

  # `reader` stands in for the board; the default knows no task.
  def run_bin(*argv, dir: @dir, reader: ->(_slug) { nil })
    out = StringIO.new
    err = StringIO.new
    code = DreamCli.new(env: { "DREAM_BANK_DIR" => dir }, out: out, err: err, task_reader: reader).run(argv)
    [ out.string, err.string, code ]
  end

  def payment_reader
    ->(slug) { slug == "settle-payout-once" ? PAYMENT : nil }
  end

  def test_unit_the_script_exits_with_the_command_code
    out, err, status = Open3.capture3({ "DREAM_BANK_DIR" => @dir }, RbConfig.ruby, BIN, "nobody")

    assert_equal 1, status.exitstatus
    assert_equal "", out
    assert_includes err, "is not a soul"
  end

  def test_unit_a_soul_prints_its_sequence_and_not_the_platform_one
    out, err, code = run_bin("carl")

    assert_equal 0, code
    assert_equal "", err
    assert_includes out, "## Carl's dream sequence\n"
    assert_includes out, "**Q: A review question?** (`review`)"
    refute_includes out, "A universal question?"
  end

  def test_unit_a_soul_with_a_task_prints_the_selected_set
    out, err, code = run_bin("pokemon", "--task", "settle-payout-once", dir: FIXTURES, reader: payment_reader)

    assert_equal 0, code
    assert_equal "", err
    assert_includes out, "## Pokémon's dream sequence · task settle-payout-once"
    assert_includes out, "(`settle-once-per-entry`)"
    assert_includes out, "### Platform dreams"
    refute_includes out, "docs-guard-names-its-rule"
    assert_includes out, "4 not shown: bin/dream list --task settle-payout-once"
  end

  def test_unit_an_unread_task_prints_the_whole_sequence_and_says_so
    readers = { "knows no task" => ->(_slug) { nil }, "raises" => ->(_slug) { raise IOError, "board down" } }
    readers.each do |label, reader|
      out, err, code = run_bin("pokemon", "--task", "some-task", dir: FIXTURES, reader: reader)

      assert_equal 0, code, label
      assert_equal "dream: could not read task `some-task` from the board; printing unranked.\n", err, label
      assert_includes out, "## Pokémon's dream sequence · task some-task", label
      assert_includes out, "docs-guard-names-its-rule", "#{label}: the unselected sequence holds every dream"
      refute_includes out, "### Platform dreams", label
    end
  end

  def test_unit_list_ranks_every_approved_dream_for_the_task_with_its_file
    out, err, code = run_bin("list", "--task", "settle-payout-once", dir: FIXTURES, reader: payment_reader)
    rows = out.lines.grep(/`/)

    assert_equal 0, code
    assert_equal "", err
    assert_equal "## Approved dreams, ranked for task settle-payout-once\n", out.lines.first
    assert_equal 18, rows.size, "every approved dream, whoever it belongs to"
    assert_equal "score 10 · `settle-once-per-entry` · pokemon · #{FIXTURES}/pokemon/settle-once-per-entry.md\n", rows.first
    assert_includes out, "score 0 · `docs-guard-names-its-rule` · pokemon · #{FIXTURES}/pokemon/docs-guard-names-its-rule.md"
    assert_includes out, "score 6 · `money-review-reads-the-ledger` · carl · "
    assert_includes out, "  Q: A payout job may run twice. What stops a double payment?"
    refute_includes out, "proposed-money-idea", "control: a proposed dream is not listed"
    rows.each { |row| assert File.exist?(row[%r{/\S+\.md}]), row }
  end

  def test_unit_list_without_a_readable_task_is_unranked_and_still_exits_zero
    plain, err, code = run_bin("list", dir: FIXTURES)
    assert_equal [ 0, "" ], [ code, err ]
    assert_equal "## Approved dreams\n", plain.lines.first
    refute_includes plain, "score "
    assert_equal 18, plain.lines.grep(/`/).size

    out, err, code = run_bin("list", "--task", "some-task", dir: FIXTURES)
    assert_equal 0, code
    assert_equal "dream: could not read task `some-task` from the board; printing unranked.\n", err
    assert_equal plain, out
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
    assert_includes out, "bin/dream list [--task <slug>]"
    refute File.exist?(File.join(@dir, "INDEX.md")), "--help is inert"

    read = []
    reader = ->(slug) { read << slug && nil }
    out, _err, code = run_bin("list", "--task", "some-task", "--help", reader: reader)
    assert_equal 0, code
    assert_includes out, "bin/dream list [--task <slug>]"
    assert_empty read, "--help reads no task"

    [ [], %w[index --rewrite], %w[carl --task], %w[carl extra], %w[platform extra], %w[list --bogus], %w[list --task],
      %w[list extra], %w[list --task some-task extra], [ "list", "--task", "../auth" ],
      [ "carl", "--task", "Not A Slug" ] ].each do |argv|
      out, err, code = run_bin(*argv, reader: reader)
      assert_equal 2, code, argv.inspect
      assert_equal "", out
      assert_includes err, "bin/dream list [--task <slug>]"
      assert_empty read, "#{argv.inspect} reads no task"
    end
  end
end
