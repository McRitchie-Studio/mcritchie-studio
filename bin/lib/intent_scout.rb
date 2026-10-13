# frozen_string_literal: true

require "open3"
require "uri"
require_relative "projects_root"
require_relative "remedy"

# THE INTENT SCOUT: Avi reads a task's INTENT (title and acceptance), not its diff,
# while the builder builds, and hands the builder every surface the intent touches
# BEFORE the CI wait. The procedure is docs/agents/agents/avi/sops/intent-scout.md.
#
# WHY (2026-10-13, team-tier-nine-hundred): a builder changed the Team tier price on
# /packages, searched too narrowly, and missed test/views/stack_view_test.rb. CI went
# red and the round trip cost twelve minutes. A scout reading the intent in parallel
# would have named that test before the push.
#
# THE MECHANISM IS AN EXISTING NOTE, NOT A COLUMN. The brief is a `comment` note
# whose text begins with BRIEF_MARKER, posted the way Avi already posts `RULING:`
# notes:
#
#   bin/task note <slug> --comment "INTENT SCOUT BRIEF: ..." --agent avi
#
# `bin/task begin` records that a scout is owed (a comment beginning OWED_MARKER) and
# prints the launch line; `bin/task scout-brief <slug>` reads the brief back; and
# `bin/submit` warns at 0/8 when none is on the task. INFORMATION, NEVER A GATE: no
# caller refuses or waits on a scout, and each keeps the exit status it had.
#
# Pure Ruby with no Rails, so bin/task and bin/submit can both load it.
module IntentScout
  SOP_PATH = "docs/agents/agents/avi/sops/intent-scout.md"
  BRIEF_MARKER = "INTENT SCOUT BRIEF"
  OWED_MARKER = "INTENT SCOUT OWED"
  NOTE_TYPE = "comment"
  # The board's page ceiling (Api::Paginatable). The brief is searched for in the
  # newest PER_PAGE comments; a task with more than that reads as briefless, which
  # costs a warning, never a refusal.
  PER_PAGE = 100
  # The scout's board calls are best-effort, so each gets a short deadline of its
  # own: a degraded board costs begin or submit seconds, never 30 to 60 of them.
  # INTENT_SCOUT_TIMEOUT overrides it (the tests' seam).
  BOARD_TIMEOUT = 5
  # bin/submit's wall-clock bound on the whole `bin/task scout-brief` child: Ruby
  # start, a token, and one bounded read.
  SUBMIT_TIMEOUT = 15

  module_function

  def board_timeout
    Float(ENV.fetch("INTENT_SCOUT_TIMEOUT", BOARD_TIMEOUT))
  rescue ArgumentError
    BOARD_TIMEOUT
  end

  def submit_timeout
    Float(ENV.fetch("INTENT_SCOUT_SUBMIT_TIMEOUT", SUBMIT_TIMEOUT))
  rescue ArgumentError
    SUBMIT_TIMEOUT
  end

  # A child that ended on a signal has no exit status to read.
  class ChildDied < StandardError; end

  # Run `cmd`, killing it past `timeout` seconds. Returns [stdout, stderr, exit
  # status], with :timeout in place of the status when the deadline passed. Raises
  # when the child cannot start (Errno::ENOENT) or ends on a signal (ChildDied).
  def run_bounded(cmd, timeout)
    Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait|
      stdin.close
      readers = [stdout, stderr].map { |io| Thread.new { io.read }.tap { |t| t.report_on_exception = false } }
      unless wait.join(timeout)
        begin
          Process.kill("KILL", -wait.pid)
        rescue StandardError
          nil
        end
        wait.join
        next ["", "", :timeout]
      end
      status = wait.value
      raise ChildDied, "#{File.basename(cmd.first.to_s)} died on signal #{status.termsig}" unless status.exitstatus

      [readers[0].value.to_s, readers[1].value.to_s, status.exitstatus]
    end
  end

  # An older bin/task with no `scout-brief` answers an unknown subcommand by
  # printing its usage (a line beginning "Usage:") and exiting 1. Ruby or bundler
  # warnings may come first, so the line is matched anywhere. A board error prints
  # an "error:" line instead, and a newer bin/task's usage names scout-brief.
  def missing_subcommand?(exit_status, stderr)
    exit_status == 1 && stderr.to_s.match?(/^Usage:/) && !stderr.to_s.include?("scout-brief")
  end

  # The SOP as an absolute path in the hub primary, so the line resolves from any
  # desk and from the fixed-path tooling install alike.
  def sop_path(repo_root = ProjectsRoot::REPO_ROOT)
    File.join(ProjectsRoot.hub_checkout(repo_root), SOP_PATH)
  end

  # The activities query that lists a task's comment notes, newest first.
  def activities_query(slug)
    URI.encode_www_form(task_slug: slug, activity_type: NOTE_TYPE, per_page: PER_PAGE)
  end

  def marked?(activity, marker)
    return false unless activity.is_a?(Hash)
    return false unless activity["activity_type"].to_s == NOTE_TYPE

    activity["description"].to_s.lstrip.upcase.start_with?(marker)
  end

  # A brief is a comment note whose text begins with BRIEF_MARKER, in any case.
  # The OWED note begin posts is not a brief, so it never silences the warning.
  def brief?(activity)
    marked?(activity, BRIEF_MARKER)
  end

  # The newest brief in `activities` (the board lists newest first), or nil.
  def find_brief(activities)
    Array(activities).find { |activity| brief?(activity) }
  end

  # The note `bin/task begin` posts when it claims a task: a scout is owed.
  def owed_note(slug, desk)
    "#{OWED_MARKER}: Avi owes #{slug} an intent scout (#{sop_path}). " \
      "Desk, read only: #{desk}. The brief lands here as a comment beginning #{BRIEF_MARKER}."
  end

  # The prompt the launching session hands an `avi` subagent.
  def launch_prompt(slug, desk)
    "Run the intent-scout SOP at #{sop_path} for task #{slug}. The builder's desk is #{desk}: " \
      "read it, never edit it. Read the task's intent and acceptance, find every surface each " \
      "criterion touches, and post ONE brief: bin/task note #{slug} --comment " \
      "\"#{BRIEF_MARKER}: ...\" --agent avi. Two lists only: SAME INTENT, DO NOW and WIDER SCOPE, FOLLOW-UP."
  end

  # What `bin/task begin` prints after the handoff line. A paste-ready launch, never
  # a wait: begin has already finished the claim when it prints this.
  def begin_lines(slug, desk)
    [
      "scout: Avi owes this task an intent scout (#{sop_path}).",
      "  Launch it now in the background and keep building; nothing waits on it:",
      "  Agent(subagent_type: \"avi\", run_in_background: true, description: \"Intent scout #{slug}\",",
      "        prompt: #{launch_prompt(slug, desk).inspect})",
      "  Read the brief before you submit: #{task_cmd} scout-brief #{slug}"
    ]
  end

  # What `bin/submit` prints at 0/8 when the task carries no brief. A WARNING only.
  def warning_lines(slug)
    [
      "WARNING: no intent-scout brief on #{slug} (a comment beginning #{BRIEF_MARKER}). " \
      "Submitting anyway; this is not a gate.",
      "  Avi's SOP: #{sop_path}. Launch the scout from the begin line, read the brief, " \
      "and fold in its SAME INTENT, DO NOW list before the next submit."
    ]
  end

  # What `bin/submit` prints at 0/8 when the board could not be read.
  def unreadable_line(slug)
    "WARNING: could not read #{slug}'s notes for an intent-scout brief; submitting anyway (#{sop_path})."
  end

  # What `bin/submit` prints at 0/8 when its bin/task predates `scout-brief`: the
  # two scripts come from different versions, which is not a board problem.
  def missing_subcommand_line(slug, task_bin)
    "WARNING: #{task_bin} has no scout-brief subcommand (it is older than this bin/submit), so " \
      "#{slug}'s intent-scout brief was not checked; submitting anyway. Run both from the same tree (#{sop_path})."
  end

  # What `bin/submit` prints at 0/8 when the read passed its deadline.
  def timeout_line(slug, seconds)
    "WARNING: the intent-scout brief read for #{slug} passed its #{seconds.round}s deadline; submitting anyway (#{sop_path})."
  end

  # The absolute bin/task a builder pastes (bin/lib/remedy.rb).
  def task_cmd
    Remedy.command("task", File.expand_path("..", __dir__))
  end
end
