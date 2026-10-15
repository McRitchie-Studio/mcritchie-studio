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
    assert_equal 20, rows.size, "every approved dream, whoever it belongs to, step dreams included"
    assert_includes out, "`read-ci-before-the-diff` · sops/pr-review · #{FIXTURES}/sops/pr-review/read-ci-before-the-diff.md"
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
    assert_equal 20, plain.lines.grep(/`/).size

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

  PROPOSAL = <<~DREAM
    ---
    question: "A reviewer blocks my PR and the block is wrong: do I fix it anyway?"
    answer: "Contest it with the evidence."
    why: "A needless fix costs a bounce."
    status: proposed
    source: "task guard-nil-reader · overruled_block · activity-1, activity-2"
    soul: carl
    repo: [mcritchie-studio]
    ---

    # Guard The Nil Reader
  DREAM

  # A throwaway desk with a bank; returns [desk, bank].
  def desk(name = "some-desk")
    root = File.join(@dir, "repo", ".worktrees", name)
    bank = File.join(root, "docs/agents/dreams")
    FileUtils.mkdir_p(File.join(bank, "platform"))
    File.write(File.join(bank, "platform/universal.md"), dream("A universal question?"))
    [ root, bank ]
  end

  # Every file under the throwaway directory, dot directories included.
  def every_file
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @dir).select { |path| File.file?(File.join(@dir, path)) }.sort
  end

  def materialize(*argv, cwd:, body: PROPOSAL, read: [])
    out = StringIO.new
    err = StringIO.new
    reader = ->(slug) { read << slug && body && { "slug" => slug, "body" => body } }
    code = DreamCli.new(env: { "DREAM_BANK_DIR" => @dir }, out: out, err: err, finding_reader: reader, cwd: cwd).run(argv)
    [ out.string, err.string, code ]
  end

  def test_integration_materialize_writes_the_proposed_dream_into_the_desk
    root, bank = desk
    path = File.join(bank, "carl/guard-nil-reader.md")

    out, err, code = materialize("propose", "--materialize", "dream-proposal-guard-nil-reader", cwd: File.join(root, "docs"))

    assert_equal [ 0, "" ], [ code, err ]
    assert_includes out, "dream: wrote #{path} (status proposed)"
    assert_equal PROPOSAL, File.read(path)
    assert_includes File.read(path), "\nstatus: proposed\n"
    assert_includes File.read(path), "task guard-nil-reader"
    assert_equal %w[carl/review.md platform/universal.md repo/.worktrees/some-desk/docs/agents/dreams/carl/guard-nil-reader.md
                    repo/.worktrees/some-desk/docs/agents/dreams/platform/universal.md], every_file,
                 "the one new file is in the desk's bank"
  end

  def test_integration_a_materialized_dream_loads_nowhere_and_the_index_marks_it_proposed
    root, bank = desk
    materialize("propose", "--materialize", "dream-proposal-guard-nil-reader", cwd: root)

    assert_equal %w[guard-nil-reader universal], DreamBank.all(dir: bank).map(&:slug), "the file passes the validator"
    assert_empty DreamBank.soul("carl", dir: bank)
    assert_equal %w[universal], DreamBank.approved(dir: bank).map(&:slug)
    refute_includes run_bin("carl", dir: bank).first, "A reviewer blocks my PR"
    refute_includes run_bin("list", dir: bank).first, "guard-nil-reader"

    assert_equal 0, run_bin("index", "--write", dir: bank).last
    assert_equal 0, run_bin("index", "--check", dir: bank).last
    rows = File.read(File.join(bank, "INDEX.md")).lines.grep(/guard-nil-reader/)
    assert_equal 1, rows.size
    assert_match(/\| proposed \|$/, rows.first)
  end

  def test_unit_materialize_refuses_outside_a_desk_and_reads_nothing
    _root, bank = desk("_gate")
    [ @dir, File.join(@dir, "repo"), File.dirname(bank) ].each do |cwd|
      read = []
      out, err, code = materialize("propose", "--materialize", "dream-proposal-guard-nil-reader", cwd: cwd, read: read)

      assert_equal [ 1, "" ], [ code, out ], cwd
      assert_includes err, "is not inside one"
      assert_empty read
    end
    assert_empty every_file.grep(/guard-nil-reader/)
  end

  def test_unit_materialize_refuses_a_desk_with_no_bank
    root = File.join(@dir, "other", ".worktrees", "some-desk")
    FileUtils.mkdir_p(root)

    _out, err, code = materialize("propose", "--materialize", "dream-proposal-guard-nil-reader", cwd: root)

    assert_equal 1, code
    assert_includes err, "has no docs/agents/dreams/"
    assert_empty Dir.glob("#{root}/**/*.md")
  end

  def test_unit_materialize_never_overwrites
    root, bank = desk
    path = File.join(bank, "carl/guard-nil-reader.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "mine")

    out, err, code = materialize("propose", "--materialize", "dream-proposal-guard-nil-reader", cwd: root)

    assert_equal [ 1, "" ], [ code, out ]
    assert_includes err, "exists; it is not overwritten"
    assert_equal "mine", File.read(path)
  end

  def test_unit_materialize_refuses_a_finding_that_is_not_a_proposed_dream_for_one_known_soul
    root, bank = desk
    { "approved" => PROPOSAL.sub("status: proposed", "status: approved"),
      "platform" => PROPOSAL.sub("soul: carl\n", ""),
      "two souls" => PROPOSAL.sub("soul: carl", "soul: [carl, xan]"),
      "unknown soul" => PROPOSAL.sub("soul: carl", "soul: nobody"),
      "unknown key" => PROPOSAL.sub("soul: carl", "soul: carl\nowner: carl"),
      "no front matter" => "# A title\n" }.each do |label, body|
      out, err, code = materialize("propose", "--materialize", "dream-proposal-guard-nil-reader", cwd: root, body: body)

      assert_equal [ 1, "" ], [ code, out ], label
      assert_includes err, "does not hold a proposed dream for one known soul", label
    end

    _out, err, code = materialize("propose", "--materialize", "dream-proposal-guard-nil-reader", cwd: root, body: nil)
    assert_equal 1, code
    assert_includes err, "could not read finding"
    assert_equal [ "#{bank}/platform/universal.md" ], Dir.glob("#{bank}/**/*.md")
  end

  def test_unit_propose_help_is_inert_and_an_unplaced_argument_is_usage
    root, bank = desk
    read = []
    out, _err, code = materialize("propose", "--materialize", "dream-proposal-guard-nil-reader", "--help", cwd: root, read: read)
    assert_equal 0, code
    assert_includes out, "bin/dream propose --materialize <finding>"

    [ %w[propose], %w[propose --materialize], %w[propose --write dream-proposal-guard-nil-reader],
      %w[propose --materialize finding-abc123], %w[propose --materialize dream-proposal-../x],
      %w[propose --materialize dream-proposal-guard-nil-reader extra],
      %w[propose dream-proposal-guard-nil-reader] ].each do |argv|
      out, err, code = materialize(*argv, cwd: root, read: read)
      assert_equal [ 2, "" ], [ code, out ], argv.inspect
      assert_includes err, "bin/dream propose --materialize <finding>"
    end
    assert_empty read, "no refused call reads the board"
    assert_equal [ "#{bank}/platform/universal.md" ], Dir.glob("#{bank}/**/*.md")
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
  # ── approvals, apply-approvals and fired ─────────────────────────────────

  def approvals_cli(*argv, rows:, cwd: @dir, reports: nil, recorded: true)
    out = StringIO.new
    err = StringIO.new
    reporter = ->(args) { reports << args if reports; [ recorded, recorded ? "ok" : "atomic-event action: no open activity — skipped" ] }
    code = DreamCli.new(env: { "DREAM_BANK_DIR" => @dir }, out: out, err: err, approvals_reader: -> { rows },
                        fire_reporter: reporter, cwd: cwd).run(argv)
    [ out.string, err.string, code ]
  end

  def pending(home, slug, status = "proposed")
    { "dream_home" => home, "dream_slug" => slug, "approved_by" => "alex-mcritchie",
      "approved_at" => "2026-10-15T12:00:00Z", "file_status" => status }
  end

  def test_unit_approvals_lists_each_pending_row
    out, err, code = approvals_cli("approvals", rows: [ pending("carl", "guard-nil-reader") ])

    assert_equal 0, code
    assert_equal "", err
    assert_includes out, "## Pending dream approvals (1)"
    assert_includes out, "`guard-nil-reader` · carl · approved 2026-10-15 by alex-mcritchie · file reads proposed"
    assert_includes out, "bin/dream apply-approvals"
  end

  def test_unit_approvals_refuses_when_the_board_cannot_be_read
    out, err, code = approvals_cli("approvals", rows: nil)

    assert_equal 1, code
    assert_equal "", out
    assert_includes err, "could not read the pending approvals"
  end

  def test_integration_apply_approvals_flips_only_proposed_files_and_rewrites_the_index
    root, bank = desk
    FileUtils.mkdir_p(File.join(bank, "carl"))
    File.write(File.join(bank, "carl/guard-nil-reader.md"), PROPOSAL)
    File.write(File.join(bank, "platform/already.md"), dream("Already approved?"))
    rows = [ pending("carl", "guard-nil-reader"), pending("platform", "already"),
             pending("platform", "gone", "missing"), pending("..", "escape") ]

    out, err, code = approvals_cli("apply-approvals", rows: rows, cwd: root)

    assert_equal 0, code
    text = File.read(File.join(bank, "carl/guard-nil-reader.md"))
    assert_includes text, "\nstatus: approved\n"
    assert_equal PROPOSAL.sub("status: proposed", "status: approved"), text, "nothing else in the file moves"
    assert_includes out, "dream: 1 of 4 pending approval(s) written; INDEX.md rewritten."
    assert_includes err, "skipped `platform/already`: the file does not read status: proposed"
    assert_includes err, "skipped `platform/gone`: no file at"
    assert_includes err, "skipped approval `../escape`: not a bank path"
    index = File.read(File.join(bank, "INDEX.md"))
    assert_match(/guard-nil-reader.*\| approved \|$/, index)
    assert_equal DreamBank.index(dir: bank), index
  end

  def test_integration_apply_approvals_reaches_a_step_dream_and_no_other_nested_path
    root, bank = desk
    FileUtils.mkdir_p(File.join(bank, "sops/qa-release"))
    step = PROPOSAL.sub("soul: carl\n", "sop: qa-release\nstep: prepare\n")
    File.write(File.join(bank, "sops/qa-release/rerun-first.md"), step)
    rows = [ pending("sops/qa-release", "rerun-first"), pending("sops/../carl", "escape"),
             pending("carl/sops", "escape"), pending("sops/a/b", "escape") ]

    out, err, code = approvals_cli("apply-approvals", rows: rows, cwd: root)

    assert_equal 0, code, err
    assert_includes step, "status: proposed", "control: the fixture starts proposed"
    assert_includes File.read(File.join(bank, "sops/qa-release/rerun-first.md")), "\nstatus: approved\n"
    assert_includes out, "dream: 1 of 4 pending approval(s) written"
    assert_equal 3, err.scan("not a bank path").size, err
  end

  def test_unit_apply_approvals_warns_when_a_layer_goes_over_budget
    root, bank = desk
    (1..16).each { |n| File.write(File.join(bank, "platform/p#{n}.md"), dream("Platform #{n}?")) }
    _out, err, code = approvals_cli("apply-approvals", rows: [], cwd: root)

    assert_equal 0, code
    assert_includes err, "dream: over budget: layer platform holds 17 approved dreams; its budget is 15."
  end

  def test_unit_apply_approvals_with_nothing_pending_writes_nothing
    root, bank = desk
    out, _err, code = approvals_cli("apply-approvals", rows: [], cwd: root)

    assert_equal 0, code
    assert_includes out, "dream: 0 of 0 pending approval(s) written."
    refute File.exist?(File.join(bank, "INDEX.md"))
  end

  def test_unit_apply_approvals_refuses_outside_a_desk
    _root, bank = desk
    File.write(File.join(bank, "platform/proposed.md"), PROPOSAL.sub("soul: carl\n", ""))
    out, err, code = approvals_cli("apply-approvals", rows: [ pending("platform", "proposed") ], cwd: @dir)

    assert_equal 1, code
    assert_equal "", out
    assert_includes err, "is not inside one"
    assert_includes File.read(File.join(bank, "platform/proposed.md")), "status: proposed"
  end

  def test_unit_fired_reports_a_dream_fired_action
    reports = []
    out, err, code = approvals_cli("fired", "universal", "--decision", "Kept  the   read-only probe", rows: [], reports: reports)

    assert_equal 0, code
    assert_equal "", err
    assert_includes out, "dream: `universal` fired · Kept the read-only probe"
    assert_equal [ [ "action", "--kind", "dream_fired", "--event-slug", "universal", "--summary", "Kept the read-only probe" ] ],
                 reports
  end

  def test_unit_fired_cuts_a_long_decision_to_what_the_board_keeps
    reports = []
    _out, err, code = approvals_cli("fired", "universal", "--decision", "x" * 200, rows: [], reports: reports)

    assert_equal 0, code
    assert_includes err, "cut to 160 characters"
    assert_equal 160, reports.first.last.size
  end

  def test_unit_fired_refuses_an_unknown_dream_and_reports_nothing
    reports = []
    out, err, code = approvals_cli("fired", "no-such-dream", "--decision", "Something", rows: [], reports: reports)

    assert_equal 1, code
    assert_equal "", out
    assert_includes err, "`no-such-dream` is not a dream"
    assert_empty reports
  end

  def test_unit_fired_says_so_when_nothing_was_recorded
    out, err, code = approvals_cli("fired", "universal", "--decision", "Something", rows: [], recorded: false)

    assert_equal 1, code
    assert_equal "", out
    assert_includes err, "nothing was recorded: atomic-event action: no open activity"
  end

  def test_unit_fired_and_approvals_take_exact_arguments
    reports = []
    [ %w[fired], %w[fired universal], %w[fired universal --decision], [ "fired", "universal", "--decision", "  " ],
      [ "fired", "Not A Slug", "--decision", "x" ], %w[fired universal --why x], %w[approvals extra],
      %w[apply-approvals --mark] ].each do |argv|
      out, err, code = approvals_cli(*argv, rows: [], reports: reports)
      assert_equal 2, code, argv.inspect
      assert_equal "", out
      assert_includes err, "bin/dream fired <slug>"
    end
    assert_empty reports
  end
end
