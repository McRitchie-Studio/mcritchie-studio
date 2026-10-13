# frozen_string_literal: true

require "minitest/autorun"
require "uri"
require_relative "../../bin/lib/intent_scout"

# [unit] The intent-scout brief: what counts as one, and the lines bin/task begin and
# bin/submit print about it (docs/agents/agents/avi/sops/intent-scout.md). No board,
# no subprocess: the wiring is pinned in test/lib/task_begin_test.rb,
# test/lib/submit_test.rb and test/lib/intent_scout_flow_test.rb.
class IntentScoutTest < Minitest::Test
  def note(description, type: "comment", **extra)
    { "activity_type" => type, "description" => description }.merge(extra.transform_keys(&:to_s))
  end

  def test_a_comment_beginning_with_the_marker_is_a_brief
    assert IntentScout.brief?(note("INTENT SCOUT BRIEF: SAME INTENT, DO NOW ..."))
    assert IntentScout.brief?(note("  intent scout brief\nSAME INTENT, DO NOW")), "case and leading space are forgiven"
  end

  def test_the_owed_note_begin_posts_is_not_a_brief
    owed = note(IntentScout.owed_note("demo-task", "/tmp/desk"))

    assert owed["description"].start_with?(IntentScout::OWED_MARKER)
    refute IntentScout.brief?(owed), "the owed record must never silence the submit warning"
  end

  def test_only_a_comment_note_carries_a_brief
    %w[handoff clarification qa_feedback].each do |type|
      refute IntentScout.brief?(note("INTENT SCOUT BRIEF: x", type: type)), "#{type} is not the brief's note type"
    end
  end

  def test_a_marker_inside_the_text_is_not_a_brief
    refute IntentScout.brief?(note("RULING: OVERRULE. The INTENT SCOUT BRIEF said otherwise."))
    refute IntentScout.brief?(note(""))
    refute IntentScout.brief?(nil)
    refute IntentScout.brief?("INTENT SCOUT BRIEF: a bare string is not an activity")
  end

  def test_find_brief_takes_the_newest_brief_from_a_newest_first_list
    rows = [
      note("Avi shirt-sized this task small."),
      note("INTENT SCOUT BRIEF: second", slug: "newer"),
      note("INTENT SCOUT OWED: ..."),
      note("INTENT SCOUT BRIEF: first", slug: "older")
    ]

    assert_equal "newer", IntentScout.find_brief(rows)["slug"]
    assert_nil IntentScout.find_brief(rows.values_at(0, 2))
    assert_nil IntentScout.find_brief(nil)
  end

  def test_the_query_lists_the_tasks_comment_notes_at_the_page_ceiling
    query = URI.decode_www_form(IntentScout.activities_query("demo-task")).to_h

    assert_equal({ "task_slug" => "demo-task", "activity_type" => "comment", "per_page" => "100" }, query)
  end

  def test_the_sop_path_is_absolute_and_names_the_file_that_exists
    path = IntentScout.sop_path

    assert path.start_with?("/"), "a builder on any desk must be able to open it"
    assert path.end_with?(IntentScout::SOP_PATH)
    assert File.file?(File.expand_path("../../#{IntentScout::SOP_PATH}", __dir__)), "the SOP the lines name must exist"
  end

  def test_the_submit_warning_names_the_sop_and_says_it_is_not_a_gate
    text = IntentScout.warning_lines("demo-task").join("\n")

    assert text.start_with?("WARNING: no intent-scout brief on demo-task")
    assert_includes text, IntentScout::SOP_PATH
    assert_includes text, "not a gate"
    assert_includes text, "SAME INTENT, DO NOW"
  end

  def test_the_begin_lines_hand_over_a_background_avi_launch_for_this_task_and_desk
    lines = IntentScout.begin_lines("demo-task", "/projects/hub/.worktrees/demo-task")
    text = lines.join("\n")

    assert lines.first.start_with?("scout: "), "one recognisable lead line"
    assert_includes text, 'subagent_type: "avi"'
    assert_includes text, "run_in_background: true", "the scout must never hold the builder"
    assert_includes text, "/projects/hub/.worktrees/demo-task"
    assert_includes text, "never edit it", "the scout reads the desk only"
    assert_includes text, "#{IntentScout::BRIEF_MARKER}:", "the prompt names the marker the reader looks for"
    assert_includes text, "SAME INTENT, DO NOW"
    assert_includes text, "WIDER SCOPE, FOLLOW-UP"
    assert_includes text, "scout-brief demo-task", "the builder is told how to read the brief back"
    refute(lines.any? { |line| line.lstrip.start_with?("cd ") }, "begin's handoff stays the only cd line")
  end

  # --- version skew and bounded reads (bin/submit's 0/8 read) -------------------

  def test_an_older_bin_task_usage_reads_as_a_missing_subcommand
    assert IntentScout.missing_subcommand?(1, "Usage:\n  bin/task list [--stage S]\n")
    assert IntentScout.missing_subcommand?(1, "warning: already initialized constant X\nUsage:\n  bin/task list\n"),
           "a warning line ahead of the usage (bundler under fast-check) still reads as version skew"
    refute IntentScout.missing_subcommand?(1, "error: GET /api/v1/activities?x -> 500: boom\n"), "a board error"
    refute IntentScout.missing_subcommand?(1, "Usage:\n  bin/task scout-brief <slug>\n"), "a newer usage names it"
    refute IntentScout.missing_subcommand?(2, "Usage:\n"), "exit 2 is no brief yet"
    line = IntentScout.missing_subcommand_line("demo-task", "/x/bin/task")
    assert_includes line, "/x/bin/task has no scout-brief subcommand"
    refute_includes line, "could not read"
  end

  def test_the_bounded_runner_reports_status_timeout_and_raises
    out, _err, status = IntentScout.run_bounded(["/bin/sh", "-c", "echo hi; exit 3"], 5)
    assert_equal ["hi\n", 3], [out, status]

    _out, _err, status = IntentScout.run_bounded(["/bin/sh", "-c", "sleep 30"], 0.5)
    assert_equal :timeout, status

    assert_raises(Errno::ENOENT) { IntentScout.run_bounded(["/no/such/bin/task"], 5) }
    assert_raises(IntentScout::ChildDied) { IntentScout.run_bounded(["/bin/sh", "-c", "kill -9 $$"], 5) }
  end

  def test_the_board_deadline_is_short_and_overridable
    assert_operator IntentScout::BOARD_TIMEOUT, :<=, 10
    ENV["INTENT_SCOUT_TIMEOUT"] = "2"
    assert_in_delta 2.0, IntentScout.board_timeout
  ensure
    ENV.delete("INTENT_SCOUT_TIMEOUT")
  end
end
