# frozen_string_literal: true

# Guard catalog row 2.4 (decision 2): the `docs` claim classifies a Ruby edit by its
# comment-free token stream, and admits guard tests by NAME under any test/ directory.
#   ruby -Itest test/lib/dor_check_docs_comment_only_test.rb
#
# Driven through bin/dor-check over a REAL git repo (base commit, then an edit), so
# the merge-base read, the Ripper comparison and the claim are all on the path.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../../bin/lib/ruby_comment_diff"
require_relative "../../bin/lib/code_diff"

class DorCheckDocsCommentOnlyTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)

  DOCS_CONTRACT = {
    "kind" => "bug", "shape" => "docs", "repositories" => ["mcritchie-studio"],
    "risk_tags" => ["docs"], "acceptance" => ["Runbook names the correct command"],
    "test_plan" => ["prose review"], "post_deploy_cmd" => "none"
  }.freeze

  SERVICE = <<~RUBY
    # frozen_string_literal: true

    # Says hello.
    class Greeter
      def call = "hi"
    end
  RUBY

  def git!(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # A repo whose base commit holds app/services/greeter.rb; `edits` are applied on top
  # and committed, the way bin/submit leaves a desk before the gate runs.
  def verdict_after(edits)
    Dir.mktmpdir do |dir|
      git!(dir, "init", "-q")
      git!(dir, "config", "user.email", "t@t.co")
      git!(dir, "config", "user.name", "T")
      write(dir, "app/services/greeter.rb", SERVICE)
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "base")
      git!(dir, "branch", "base-ref")
      edits.each { |rel, body| write(dir, rel, body) }
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "edit")

      task = File.join(dir, "..", "#{File.basename(dir)}-task.json")
      File.write(task, JSON.generate("slug" => "t", "title" => "T", "metadata" => { "devops" => DOCS_CONTRACT }))
      env = OutboundSeams.env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "base-ref",
                              "DOR_CHECK_CI_STATUS" => "green", "DOR_CHECK_PR_FILES" => "")
      out = IO.popen(env, [BIN, "--file", task, { err: File::NULL }], &:read)
      [out, $?.exitstatus]
    ensure
      FileUtils.rm_f(task) if task
    end
  end

  def test_a_comment_only_ruby_edit_rides_a_docs_claim
    out, code = verdict_after("docs/note.md" => "prose\n",
                              "app/services/greeter.rb" => SERVICE.sub("# Says hello.", "# Says hello, politely."))

    assert_equal 0, code, out
  end

  def test_a_ruby_edit_that_changes_code_is_still_refused
    out, code = verdict_after("docs/note.md" => "prose\n",
                              "app/services/greeter.rb" => SERVICE.sub('"hi"', '"hello"'))

    refute_equal 0, code, out
    assert_match(%r{app/services/greeter\.rb}, out)
  end

  def test_a_magic_comment_change_is_a_code_change
    out, code = verdict_after("docs/note.md" => "prose\n",
                              "app/services/greeter.rb" => SERVICE.sub("# frozen_string_literal: true\n", ""))

    refute_equal 0, code, out
  end

  def test_a_guard_test_by_name_rides_a_docs_claim_from_any_test_directory
    out, code = verdict_after("docs/note.md" => "prose\n",
                              "test/lib/shift_argument_guard_test.rb" => "# guard\n")

    assert_equal 0, code, out
  end

  def test_an_ordinary_test_outside_test_docs_is_still_refused
    out, code = verdict_after("docs/note.md" => "prose\n", "test/lib/thing_test.rb" => "# test\n")

    refute_equal 0, code, out
    assert_match(%r{test/lib/thing_test\.rb}, out)
  end

  # ---- the classifier, unit level ----

  def test_unit_token_streams_ignore_comments_and_keep_code
    assert RubyCommentDiff.comment_only_change?("x = 1\n", "# lead\nx = 1 # trailing\n")
    refute RubyCommentDiff.comment_only_change?("a\nb\n", "a b\n"), "a statement break is code"
    refute RubyCommentDiff.comment_only_change?("x = 1\n", "x = 1\n"), "an unchanged file grants nothing"
    refute RubyCommentDiff.comment_only_change?("x = 1\n", "x = (\n"), "source that does not lex fails closed"
    refute RubyCommentDiff.comment_only_change?("x\n__END__\na\n", "x\n__END__\nb\n"), "DATA is not a comment"
  end

  def test_unit_guard_tests_are_admitted_by_name
    assert CodeDiff.docs_guard_test?("test/lib/devops_shift_argument_guard_test.rb")
    assert CodeDiff.docs_guard_test?("test/docs/sop_registry_docs_test.rb")
    refute CodeDiff.docs_guard_test?("test/lib/thing_test.rb")
    refute CodeDiff.docs_guard_test?("app/models/x_guard_test.rb")
  end
end
