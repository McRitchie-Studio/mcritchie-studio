# frozen_string_literal: true

# Unit tests for MergePermitCli: the reads behind bin/merge-permit and its three
# exits (0 permit, 2 refused, 1 a read failed). The board and GitHub are fakes, so
# no PR is read and nothing can be merged from here.
#
# Run directly:  ruby -Itest test/lib/merge_permit_cli_test.rb

require "minitest/autorun"
require "stringio"
require_relative "../../bin/lib/merge_permit_cli"
require_relative "../../bin/lib/pr_file_list"

class MergePermitCliTest < Minitest::Test
  HEAD = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
  LATER = "ffffffffffffffffffffffffffffffffffffffff"
  PR = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/4242"
  SOULS = %w[xan carl shannon jasper steffon avi pokemon].freeze

  class FakeBoard
    attr_accessor :task_record, :reports, :task_error, :reports_error
    attr_reader :calls

    def initialize
      @calls = []
    end

    def task(slug)
      @calls << [:task, slug]
      task_error ? [nil, task_error] : [task_record, nil]
    end

    def scout_reports(slug)
      @calls << [:scout_reports, slug]
      reports_error ? [nil, reports_error] : [reports, nil]
    end
  end

  class FakeGithub
    attr_accessor :heads, :file_list, :commits, :errors
    attr_reader :calls

    def initialize
      @calls = []
      @errors = {}
    end

    def head(_url) = respond(:head) { heads.size > 1 ? heads.shift : heads.first }
    def files(_url) = respond(:files) { file_list }
    def commit_text(_url) = respond(:commit_text) { commits }

    private

    def respond(name)
      @calls << name
      errors[name] ? [nil, errors[name]] : [yield, nil]
    end
  end

  def setup
    @board = FakeBoard.new
    @board.task_record = { "slug" => "tidy-the-sop", "metadata" => { "devops" => { "pr_url" => PR, "built_by" => "pokemon",
                                                                                   "builders" => %w[pokemon] } } }
    @board.reports = [report("merge-ready", "xan", HEAD, "2026-10-08T10:00:00Z", 2)]
    @github = FakeGithub.new
    @github.heads = [HEAD]
    @github.file_list = %w[docs/agents/modules/focus-session.md test/docs/focus_session_docs_test.rb]
    @github.commits = "pokemon@mcritchie.studio\nnoreply@github.com\nTidy the SOP\n"
    @out = StringIO.new
    @err = StringIO.new
  end

  def report(outcome, agent, head, at, id)
    { "id" => id, "agent_slug" => agent, "created_at" => at,
      "metadata" => { "kind" => "scout_report", "outcome" => outcome, "head" => head } }
  end

  def run_cli(*argv)
    MergePermitCli.new(board: @board, github: @github, souls: SOULS, out: @out, err: @err).run(argv)
  end

  def as_xan(head = HEAD) = run_cli("tidy-the-sop", "--agent", "xan", "--head", head)

  def test_permits_the_documentation_seat_and_prints_the_pinned_merge
    assert_equal MergePermitCli::PERMIT, as_xan

    assert_match(/PERMIT tidy-the-sop: xan may merge: the diff measures docs at a1b2c3d/, @out.string)
    assert_includes @out.string, "gh pr merge #{PR} --merge --match-head-commit #{HEAD}"
    assert_empty @err.string
  end

  def test_refuses_a_code_file_with_the_rule_and_who_merges
    @github.file_list = %w[docs/a.md bin/submit]

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/REFUSED tidy-the-sop: the documentation seat \(xan\) merges docs-shape PRs only/, @err.string)
    assert_match(/measures mixed .*bin\/submit.*Carl, the standing primary, merges it/, @err.string)
    refute_includes @out.string, "gh pr merge", "a refusal must never print a merge to run"
    refute_match(/\.rb:\d+:in /, @err.string, "a refusal is a sentence, never a backtrace")
  end

  # The card says docs; the diff does not. Only the diff is read.
  def test_a_declared_docs_shape_buys_nothing
    @board.task_record["metadata"]["devops"]["shape"] = "docs"
    @board.task_record["shape"] = "docs"
    @github.file_list = %w[app/models/task.rb]

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/measures code/, @err.string)
  end

  def test_the_head_is_read_on_both_sides_of_the_file_list
    as_xan

    assert_equal %i[commit_text head files head], @github.calls
  end

  def test_refuses_when_the_head_moves_during_the_file_read
    @github.heads = [HEAD, LATER]

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/not the validated a1b2c3d/, @err.string)
  end

  def test_refuses_when_the_head_moved_after_the_verdict
    @github.heads = [LATER]

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/head is fffffff, not the validated a1b2c3d/, @err.string)
  end

  def test_refuses_the_seat_named_by_a_commit_on_the_pr
    # No stamp names her: only the PR's own commits do.
    @github.commits = "pokemon@mcritchie.studio\nTidy\n\nCo-Authored-By: Xan <xan@mcritchie.studio>\n"

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/xan is one of this PR's authors \(pokemon, xan\)/, @err.string)
  end

  def test_refuses_the_seat_named_by_a_fix_forward_or_a_retired_stamp
    @board.task_record["metadata"]["devops"]["fix_forward"] = %w[alex]

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/never merges its own work/, @err.string)
  end

  def test_refuses_when_no_roster_soul_authored_the_pr
    @board.task_record["metadata"]["devops"] = { "pr_url" => PR, "built_by" => "sess-123", "builders" => [] }
    @github.commits = "amcritchie@gmail.com\nteam@mcritchie.studio\nTidy\n"

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/author set could not be established/, @err.string)
  end

  def test_the_latest_scout_report_is_the_verdict
    @board.reports = [report("merge-ready", "xan", HEAD, "2026-10-08T10:00:00Z", 2),
                      report("request-changes", "steffon", HEAD, "2026-10-08T11:00:00Z", 3),
                      { "id" => 9, "agent_slug" => "pokemon", "created_at" => "2026-10-08T12:00:00Z", "metadata" => {} }]

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/latest verdict is a request-changes report, not merge-ready/, @err.string)
  end

  def test_refuses_a_verdict_recorded_without_a_head
    @board.reports = [report("merge-ready", "xan", nil, "2026-10-08T10:00:00Z", 2)]

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/names no head; record it again with --head a1b2c3d/, @err.string)
  end

  def test_refuses_a_card_with_no_scout_report
    @board.reports = []

    assert_equal MergePermitCli::REFUSED, as_xan
    assert_match(/latest verdict is no scout report/, @err.string)
  end

  def test_a_failed_read_is_no_permit_and_names_the_read
    { commit_text: /could not read the PR's commits/, head: /could not read the PR's head/,
      files: /could not read the PR's file list/ }.each do |read, sentence|
      setup
      @github.errors[read] = "HTTP 401: Bad credentials"

      assert_equal MergePermitCli::NO_PERMIT, as_xan, "a failed #{read} read"
      assert_match(sentence, @err.string)
      assert_match(/NO PERMIT tidy-the-sop: .*Bad credentials.*do not merge/, @err.string)
      assert_empty @out.string
    end
  end

  def test_an_unreadable_board_is_no_permit
    @board.task_error = "task tidy-the-sop failed -> HTTP 502"
    assert_equal MergePermitCli::NO_PERMIT, as_xan

    setup
    @board.reports_error = "activities failed -> HTTP 502"
    assert_equal MergePermitCli::NO_PERMIT, as_xan
    assert_match(/could not read the card's scout reports/, @err.string)
  end

  def test_a_raising_reader_is_a_sentence_not_a_backtrace
    def @github.files(_url) = raise(Errno::ENOENT, "gh")

    assert_equal MergePermitCli::NO_PERMIT, as_xan
    assert_match(/NO PERMIT tidy-the-sop: Errno::ENOENT/, @err.string)
  end

  def test_a_task_with_no_pr_is_no_permit
    @board.task_record["metadata"]["devops"].delete("pr_url")

    assert_equal MergePermitCli::NO_PERMIT, as_xan
    assert_match(/records no PR/, @err.string)
  end

  # Carl's sequence gains no read and no new way to fail.
  def test_a_soul_the_rule_does_not_limit_is_answered_without_a_read
    @github.file_list = %w[app/models/task.rb]
    @board.task_error = "the board is down"

    assert_equal MergePermitCli::PERMIT, run_cli("tidy-the-sop", "--agent", "carl", "--head", HEAD)
    assert_empty @board.calls
    assert_empty @github.calls
    assert_match(/PERMIT tidy-the-sop: carl is not a shape-limited seat/, @out.string)
  end

  def test_json_carries_the_code_and_the_merge
    assert_equal MergePermitCli::PERMIT, run_cli("tidy-the-sop", "--agent", "xan", "--head", HEAD, "--json")
    body = JSON.parse(@out.string)

    assert_equal [true, "docs_seat"], body.values_at("permitted", "code")
    assert_equal "gh pr merge #{PR} --merge --match-head-commit #{HEAD}", body["merge"]
  end

  def test_usage_errors_refuse
    assert_equal MergePermitCli::REFUSED, run_cli("--agent", "xan")
    assert_equal MergePermitCli::REFUSED, run_cli("tidy-the-sop")
    assert_equal MergePermitCli::REFUSED, run_cli("tidy-the-sop", "--agent", "xan", "--nope")
    assert_match(/usage: bin\/merge-permit/, @err.string)
  end

  # ── the shared file-list read ─────────────────────────────────────────────

  def test_the_file_list_read_lists_both_sides_of_a_rename
    args = PrFileList.gh_args("McRitchie-Studio", "mcritchie-studio", "4242")

    assert_equal ["api", "--paginate", "repos/McRitchie-Studio/mcritchie-studio/pulls/4242/files", "--jq"], args[0, 4]
    assert_includes args.last, ".previous_filename"
    assert_includes args.last, PrFileList::RENAME_SENTINEL
    assert_equal "code", MergePermission.diff_shape([PrFileList::RENAME_SENTINEL]),
                 "an unnamed rename source must classify as behavior"
    assert_equal %w[McRitchie-Studio mcritchie-studio 4242], PrFileList.parse_url(PR)
    assert_nil PrFileList.parse_url("https://mcritchie.studio/tasks/x")
    assert_equal %w[docs/a.md bin/x.sh], PrFileList.parse("docs/a.md\n\n bin/x.sh \n")
  end

  def test_the_gate_and_the_permit_share_the_read
    %w[dor-check merge-permit].each do |script|
      source = File.read(File.expand_path("../../bin/#{script}", __dir__))

      assert_includes source, "PrFileList.gh_args(owner, repo, number)", "bin/#{script} must read files through PrFileList"
    end
  end
end
