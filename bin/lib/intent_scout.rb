# frozen_string_literal: true

require "fileutils"
require "open3"
require "time"
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
  # `launch` is begin's auto_launch outcome, when it had one: the note then says
  # whether begin launched the scout itself (and its pid) or left it to the session.
  def owed_note(slug, desk, launch = nil)
    how = case launch && launch[:kind]
          when :launched then " begin launched it in the background (pid #{launch[:pid]}, log #{launch[:log]})."
          when :manual then " begin did not launch it (#{launch[:reason]}); the session launches it."
          else ""
          end
    "#{OWED_MARKER}: Avi owes #{slug} an intent scout (#{sop_path}).#{how} " \
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

  # ---------------------------------------------------------------------------
  # THE AUTO-LAUNCH (scout-launches-itself, 2026-10-13).
  #
  # WHY: on navbar-first-name-only a fresh builder ran `task begin ... | tail -30`.
  # The scout block printed BEFORE the dream bank, the dream bank ran past thirty
  # lines, and the builder never saw the block, so Avi never launched. A must-do
  # that rides on a reader noticing a printed line is a must-do that gets missed,
  # so begin now launches the scout itself: a detached, headless `claude -p` run
  # with the avi agent, logged to a per-task file, its pid recorded beside it.
  #
  # When it cannot launch (opt-out, CI, the test suite, no CLI, a failed spawn),
  # begin prints the paste-ready block instead. Never both, never twice: the pid
  # file is created EXCLUSIVELY before the spawn, so a second begin (the re-claim
  # path, or two begins racing) finds it and reports the first launch.
  # ---------------------------------------------------------------------------
  AUTO_ENV = "INTENT_SCOUT_AUTO"
  # The CLI to launch. Mirrors TASK_BEGIN_MOVE_BIN and is the TEST seam: in CI or
  # the test suite the scout launches ONLY through an explicitly named binary (a
  # stub), never through whatever `claude` PATH finds.
  BIN_ENV = "TASK_BEGIN_SCOUT_BIN"
  # Where the pid and log files live (default <projects>/.agents/intent-scout).
  HOME_ENV = "INTENT_SCOUT_HOME"
  OPT_OUT = %w[0 false no off].freeze
  # A detached scout is an agent the launching session cannot see, so it counts
  # toward First Rule 6's cap of five. At the cap begin prints the block instead.
  CAP = 5

  # The tools the headless scout may use, and nothing else: it runs with
  # --permission-mode dontAsk, so anything outside this list is DENIED rather
  # than prompted (nobody is there to answer a prompt). Read-only tools, read-only
  # git and shell reads, and the board CLIs the SOP names (`task note` posts the
  # brief; `agent-activity` narrates; `dream` loads the sequence). No Edit, no
  # Write, no git that writes: the scout never touches the desk.
  READ_ONLY_BASH = [
    "git grep *", "git -C * grep *", "git log *", "git -C * log *", "git show *", "git -C * show *",
    "grep *", "rg *", "ls *", "cat *", "head *", "tail *", "wc *", "cd *"
  ].freeze
  BOARD_SUBCOMMANDS = ["task show *", "task list *", "task note *", "task scout-brief *",
                       "agent-activity *", "dream *"].freeze

  # THE CHILD'S ENVIRONMENT IS AN ALLOW-LIST (spawned with unsetenv_others). A
  # deny-list misses the next harness variable: an inherited CLAUDE_CODE_SESSION_ID
  # or CODEX_THREAD_ID would stamp the BUILDER's session on the scout's board
  # writes, and TASK_AS_ADMIN or an admin session token must never ride along.
  # What passes: the shell basics, the locale, the board base URL (so a stub board
  # in a test stays the scout's board too), the Claude config directory, and an
  # API key when the operator runs on one rather than the laptop login.
  ENV_ALLOW = %w[PATH HOME USER LOGNAME SHELL TERM TMPDIR TZ LANG LC_ALL LC_CTYPE
                 TASK_API_BASE CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY XDG_CONFIG_HOME].freeze

  def opted_out?(env = ENV)
    OPT_OUT.include?(env.fetch(AUTO_ENV, "").to_s.strip.downcase)
  end

  def truthy?(value)
    !value.to_s.strip.empty? && !OPT_OUT.include?(value.to_s.strip.downcase)
  end

  # CI or the test suite: GitHub sets CI and GITHUB_ACTIONS; the test support arms
  # TASK_USAGE_SANDBOX for every child a test spawns; a Rails test sets RAILS_ENV.
  def automation_env?(env = ENV)
    truthy?(env["CI"]) || truthy?(env["GITHUB_ACTIONS"]) || truthy?(env["TASK_USAGE_SANDBOX"]) ||
      env["RAILS_ENV"].to_s == "test" || env["RACK_ENV"].to_s == "test"
  end

  # The claude binary to launch, or nil.
  def claude_bin(env = ENV)
    explicit = env[BIN_ENV].to_s.strip
    return (File.file?(explicit) && File.executable?(explicit) ? explicit : nil) unless explicit.empty?

    env.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "claude") }
       .find { |path| File.file?(path) && File.executable?(path) }
  end

  # Why begin will NOT auto-launch, or nil when it may.
  def auto_refusal(env = ENV)
    return "#{AUTO_ENV}=#{env[AUTO_ENV]}" if opted_out?(env)
    if env[BIN_ENV].to_s.strip.empty? && automation_env?(env)
      return "CI or the test suite; auto-launch never fires there"
    end
    return "no claude CLI found" unless claude_bin(env)
    return "no intent-scout state directory" unless state_dir(env)

    live = live_scouts(env)
    return "#{live} scouts already running, the cap is #{CAP}" if live >= CAP

    nil
  end

  # The per-task state directory, or nil when there is none to trust: in CI and
  # the test suite the operator's real .agents tree is never read or written
  # unless a test names its own (INTENT_SCOUT_HOME).
  def state_dir(env = ENV, repo_root = ProjectsRoot::REPO_ROOT)
    explicit = env[HOME_ENV].to_s.strip
    return explicit unless explicit.empty?
    return nil if automation_env?(env)

    File.join(ProjectsRoot.default_projects_dir(repo_root), ".agents", "intent-scout")
  end

  def pid_path(dir, slug) = File.join(dir, "#{slug}.pid")
  def log_path(dir, slug) = File.join(dir, "#{slug}.log")

  def alive?(pid)
    return false unless pid.to_i.positive?

    Process.kill(0, pid.to_i)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def live_scouts(env = ENV)
    dir = state_dir(env)
    return 0 unless dir && File.directory?(dir)

    Dir.glob(File.join(dir, "*.pid")).count { |path| alive?(File.read(path).strip.to_i) }
  rescue SystemCallError
    0
  end

  # An earlier launch for `slug`: { pid:, alive:, log: }, or nil. An empty pid file
  # is a launch in flight (created, not yet filled) and counts as one.
  def prior_launch(slug, env = ENV)
    dir = state_dir(env)
    return nil unless dir && File.exist?(pid_path(dir, slug))

    pid = File.read(pid_path(dir, slug)).strip.to_i
    { pid: pid, alive: alive?(pid), log: log_path(dir, slug) }
  rescue SystemCallError
    nil
  end

  def allowed_tools(bin_dirs = [])
    task_prefixes = (["bin/"] + bin_dirs.map { |d| "#{d.to_s.chomp("/")}/" }).uniq
    board = task_prefixes.flat_map { |prefix| BOARD_SUBCOMMANDS.map { |cmd| "Bash(#{prefix}#{cmd})" } }
    %w[Read Grep Glob] + READ_ONLY_BASH.map { |cmd| "Bash(#{cmd})" } + board
  end

  # The prompt a HEADLESS scout gets: the subagent prompt plus the one thing a
  # headless run must know, that nobody will answer a question.
  def headless_prompt(slug, desk)
    "#{launch_prompt(slug, desk)} You run headless, launched by bin/task begin: nobody answers " \
      "questions, so decide, post the brief with bin/task note, close your activity, and finish."
  end

  # The exact argv of the headless launch (docs/agents/agents/avi/sops/intent-scout.md).
  #   -p                          headless: run the prompt, print the answer, exit
  #   --agent avi                 Avi's soul as the session's agent
  #   --permission-mode dontAsk   deny anything not allowed below; never prompt
  #   --allowedTools ...          the read-only tools and the board CLIs (allowed_tools)
  #   --add-dir <projects>        read any repo and the builder's desk
  #   --name                      a findable session name
  def launch_command(slug, desk, bin:, projects_dir:, bin_dirs: [])
    [bin, "-p", "--agent", "avi", "--permission-mode", "dontAsk",
     "--allowedTools", allowed_tools(bin_dirs).join(","),
     "--add-dir", projects_dir, "--name", "intent-scout #{slug}",
     headless_prompt(slug, desk)]
  end

  # The child's whole environment (ENV_ALLOW, plus every LC_ locale key).
  def child_env(env = ENV)
    env.to_h.select { |key, value| value && (ENV_ALLOW.include?(key) || key.start_with?("LC_")) }
  end

  # Launch the scout detached. Returns { pid:, log: }, or { prior: {...} } when a
  # launch for `slug` already exists, and raises on a failed spawn (after removing
  # the claim, so the next begin may try again). `spawner` has Process.spawn's shape.
  def launch!(slug, desk, env: ENV, hub_dir: ProjectsRoot.hub_checkout, bin_dirs: [],
              spawner: Process.method(:spawn), detacher: Process.method(:detach))
    dir = state_dir(env) || raise(ArgumentError, "no intent-scout state directory")
    FileUtils.mkdir_p(dir)
    pid_file = pid_path(dir, slug)
    log = log_path(dir, slug)
    begin
      claim = File.open(pid_file, File::WRONLY | File::CREAT | File::EXCL, 0o644)
    rescue Errno::EEXIST
      return { prior: prior_launch(slug, env) || { pid: 0, alive: false, log: log } }
    end
    begin
      argv = launch_command(slug, desk, bin: claude_bin(env), projects_dir: File.dirname(hub_dir), bin_dirs: bin_dirs)
      File.write(log, "# intent scout for #{slug}, launched #{Time.now.utc.iso8601} by bin/task begin\n", mode: "a")
      pid = spawner.call(child_env(env), *argv, unsetenv_others: true,
                                                chdir: (File.directory?(hub_dir) ? hub_dir : Dir.pwd),
                                                pgroup: true, in: File::NULL, out: [log, "a"], err: [:child, :out])
      detacher&.call(pid)
      claim.write(pid.to_s)
      claim.close
      { pid: pid, log: log }
    rescue StandardError
      claim.close unless claim.closed?
      File.delete(pid_file) if File.exist?(pid_file)
      raise
    end
  end

  # What begin prints after it launched the scout.
  def launched_lines(slug, pid, log)
    ["scout: Avi launched in the background (pid #{pid}, log #{log}) - do not launch another; " \
     "read the brief before submit: #{task_cmd} scout-brief #{slug}"]
  end

  # What begin prints when a launch for this task already exists.
  def prior_lines(slug, prior)
    state = prior[:alive] ? "still running" : "finished"
    ["scout: Avi was already launched for this task (pid #{prior[:pid]}, #{state}, log #{prior[:log]}) - " \
     "do not launch another; read the brief before submit: #{task_cmd} scout-brief #{slug}"]
  end

  # What begin prints when the brief is already on the task (a resume).
  def brief_posted_lines(slug)
    ["scout: Avi's brief is already on this task - do not launch another; read it before submit: " \
     "#{task_cmd} scout-brief #{slug}"]
  end

  # One line for the top of begin's summary, so `head` keeps the scout too.
  def summary_line(outcome)
    case outcome[:kind]
    when :launched then "scout: Avi launched in the background (pid #{outcome[:pid]}); details at the end"
    when :prior then "scout: Avi was already launched for this task; details at the end"
    when :brief then "scout: Avi's brief is already on this task; details at the end"
    else "scout: NOT launched (#{outcome[:reason]}); launch it yourself from the block at the end"
    end
  end

  # DECIDE AND ACT, once. Returns { kind:, lines:, ... }; kind is :launched,
  # :prior, :brief or :manual (print the paste-ready block).
  #
  # A RESUME never auto-launches: the first claim launched (or printed) the scout,
  # and a begin-twice must not add a second. It reports an earlier launch from the
  # pid record, or a posted brief (brief_lookup, best-effort: a raise reads as
  # "none"), and otherwise prints the block so the session decides.
  def auto_launch(slug, desk, resume:, env: ENV, brief_lookup: nil, **launch_opts)
    prior = prior_launch(slug, env)
    return { kind: :prior, lines: prior_lines(slug, prior) } if prior

    if resume
      posted = begin
        brief_lookup&.call
      rescue StandardError, SystemExit
        false
      end
      return { kind: :brief, lines: brief_posted_lines(slug) } if posted

      return manual(slug, desk, "a resume of a building task; begin launches only on the first claim")
    end

    refusal = auto_refusal(env)
    return manual(slug, desk, refusal) if refusal

    result = launch!(slug, desk, env: env, **launch_opts)
    return { kind: :prior, lines: prior_lines(slug, result[:prior]) } if result[:prior]

    { kind: :launched, pid: result[:pid], log: result[:log], lines: launched_lines(slug, result[:pid], result[:log]) }
  rescue StandardError => e
    manual(slug, desk, "the launch failed: #{e.class}: #{e.message}")
  end

  def manual(slug, desk, reason)
    lines = begin_lines(slug, desk)
    lines.insert(1, "  Auto-launch did not run (#{reason}).")
    { kind: :manual, reason: reason, lines: lines }
  end

  # What `bin/submit` prints at 0/8 when the task carries no brief. A WARNING only.
  def warning_lines(slug)
    [
      "WARNING: no intent-scout brief on #{slug} (a comment beginning #{BRIEF_MARKER}). " \
      "Submitting anyway; this is not a gate.",
      "  Avi's SOP: #{sop_path}. bin/task begin launches the scout itself (or prints the launch " \
      "when it cannot); read the brief and fold in its SAME INTENT, DO NOW list before the next submit."
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
