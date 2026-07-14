# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../../lib/task_usage_sandbox"

# SessionMarkers — the ONE owner of the per-session narration-marker store:
#
#   <projects>/.agents/sessions/<id>.json                 active-feature marker (bin/task)
#   <projects>/.agents/sessions/<id>.acting-agent         sticky heartbeat soul (bin/atomic-event)
#   <projects>/.agents/sessions/<id>.open-activity        the open activity id (bin/atomic-event)
#   <projects>/.agents/sessions/<id>.open-span            its legacy name, cleared on close
#   <projects>/.agents/sessions/<id>.activity-usage.json  per-activity usage baselines
#   <projects>/.agents/sessions/<id>.devops-shift         the held shift lane (bin/devops-shift)
#   <projects>/.agents/sessions/<id>.heartbeat            statusline's claim throttle (bash)
#
# It began as the shared READS bin/atomic-event and bin/atomic-capture-hook each
# carried a byte-for-byte copy of. It now owns the WRITES too, because the copies
# were the bug.
#
# WHY THE WRITES MOVED HERE — a live leak, and the SECOND instance of the family
# TaskUsageSandbox was built for (the first: the task-usage cost store, PR #525).
# Every writer resolved its own path by the same FALLBACK — CLAUDE_PROJECTS_DIR
# else the real projects root — and each rebuilt `safe = gsub(…)` + File.join by
# hand: four copies in bin/atomic-event, one in bin/devops-shift, one in
# bin/statusline. Six copies, six chances to skip a guard, and NOTHING that
# failed closed when a spawned test ran unpinned. test/lib/statusline_test.rb was
# exactly that process — it pinned neither CLAUDE_PROJECTS_DIR nor HOME — so
# every run of the suite wrote a 0-byte
# `.agents/sessions/2aa216f6-7565-4bf4-bd01-70793c8ba617.heartbeat` into the
# OPERATOR'S LIVE store (and shelled `bin/task heartbeat` at the real board
# behind it). Marker pollution mis-attributes activities to the wrong task, and
# the narration timeline is what the whole learning loop reads.
#
# So: the narration writers resolve through ONE builder (+marker_path+), and every
# write and delete they make goes through the +TaskUsageSandbox+ choke point
# (+write_path+). The next caller cannot hand-roll another copy without coming
# through here.
#
# WHO ELSE TOUCHES THIS STORE, precisely — do not let this list rot:
#   bin/task           WRITES <id>.json. Resolves its own path (PROJECTS_DIR is a
#                      load-time constant off ENV) but guards it at the SAME
#                      TaskUsageSandbox seam, so it is fail-closed already.
#   bin/statusline     WRITES the .heartbeat/.shift-heartbeat throttles. Bash, so
#                      it cannot call this module; it enforces rule 1 inline and
#                      leans on the Ruby CLIs it shells for rule 2 (see its header).
#   bin/agent-marker,  READ-only. Unguarded on purpose: a read cannot pollute.
#   bin/atomic-capture-hook
#
# FAIL-CLOSED vs. NARRATION-IS-NON-FATAL — the tension, and its resolution.
# Narration must NEVER block an agent's real work, so every marker write in
# bin/atomic-event and bin/devops-shift is wrapped in `rescue StandardError =>
# nil`. A guard that RAISED would therefore be swallowed into a silent skip: it
# would report nothing and the leak would continue, green. So a violation exits
# via TaskUsageSandbox's `abort` — SystemExit is not a StandardError, so it
# escapes those rescues by design.
#
# That is not a contradiction, because the two rules bind DISJOINT populations:
#
#   REAL SESSION (TASK_USAGE_SANDBOX unset) — the guard is a strict NO-OP. Not a
#     softer check: it returns the path untouched. Narration keeps its
#     best-effort contract exactly as before, a genuine IO error still degrades
#     to nil through the caller's rescue, and narration still cannot block work.
#   SANDBOXED PROCESS (TASK_USAGE_SANDBOX set — test/support/task_usage_sandbox.rb
#     sets it process-wide, so every child a test spawns inherits it) — a write
#     that cannot PROVE its destination aborts, loudly, instead of falling back
#     to a default path. The "caller" there is a test, never an agent doing real
#     work, so nothing real is ever killed.
#
# Fail-closed governs the WRITE; non-fatal governs the AGENT. Both hold at once.
#
# NOT shared here: read_open_activity — bin/atomic-event and bin/atomic-capture-hook
# genuinely drift (the hook falls back to the legacy .open-span marker and coerces
# to a positive Integer; atomic-event reads only .open-activity and returns the
# String id). bin/agent-marker is a pure READER of this store (it resolves and
# prints the marker; it writes nothing).
module SessionMarkers
  STORE = "session-marker"

  module_function

  # The marker file for +session_id+ under +projects_dir+. PURE — no guard, no IO
  # — so reads (which cannot pollute) and writes (which can) agree on the path by
  # construction, rather than by two hand-rolled copies agreeing by luck.
  # +suffix+ carries its own dot (".json", ".open-activity", …).
  def marker_path(session_id, projects_dir, suffix)
    safe = session_id.to_s.gsub(/[^A-Za-z0-9._-]/, "")
    File.join(projects_dir.to_s, ".agents", "sessions", "#{safe}#{suffix}")
  end

  # THE CHOKE POINT — resolve a marker path for MUTATION. A sandboxed process
  # that cannot prove its destination lies outside the operator's real store
  # aborts here; it never falls back to a default path.
  #
  # +env+ is the env that RESOLVED +projects_dir+ (AgentApi#env for the CLIs), not
  # necessarily the process ENV — see guard_env below.
  #
  # +state_dir+ is injectable for the same reason TaskUsageSandbox's is: a test
  # that proved the rules against the REAL state dir would have to ask the code to
  # ATTEMPT the very write the guard forbids — so a red run, or a broken fix,
  # would do the damage it is testing for. With a stand-in root, a regression
  # lands in a tmpdir instead of the operator's narration store.
  def write_path(session_id, projects_dir, suffix, env: ENV, state_dir: TaskUsageSandbox.real_state_dir)
    TaskUsageSandbox.enforce!(marker_path(session_id, projects_dir, suffix),
                              store: STORE, env: guard_env(env), state_dir: state_dir)
  end

  # The env the guard is evaluated against — deliberately assembled from TWO
  # sources, because its two rules answer to different scopes:
  #
  #   THE PIN (CLAUDE_PROJECTS_DIR) comes from the CALLER'S env, because that is
  #     what resolved projects_dir. bin/atomic-event and bin/devops-shift take an
  #     injectable env (AgentApi#env); a test that constructs one with a tmpdir
  #     pin IS correctly pinned, and reading the process ENV instead would abort
  #     it — a guard that fails closed on the happy path, which is worse than the
  #     leak it closes.
  #   THE ARMING (TASK_USAGE_SANDBOX) comes from the PROCESS ENV whenever the
  #     caller's env is silent about it. Arming is a property of the process — a
  #     test arms it for itself and every child it spawns — so an injected env
  #     that simply omits it must NOT be able to disarm the guard. Otherwise
  #     `AgentActivityCli.new(env: {})` would resolve the REAL projects root with
  #     the sandbox reading as OFF, and write the operator's store: the very hole
  #     this exists to close. An env that names it explicitly still wins.
  def guard_env(env)
    env = env.to_h
    return env if env.key?(TaskUsageSandbox::ENV_KEY)

    env.merge(TaskUsageSandbox::ENV_KEY => ENV[TaskUsageSandbox::ENV_KEY]).compact
  end

  # Write a marker, creating the sessions dir. Returns the path, or nil when the
  # IO failed — the callers' best-effort contract. A sandbox violation is NOT an
  # IO failure and does NOT return nil: it aborts (see FAIL-CLOSED above).
  def write(session_id, projects_dir, suffix, content, env: ENV, state_dir: TaskUsageSandbox.real_state_dir)
    path = write_path(session_id, projects_dir, suffix, env: env, state_dir: state_dir)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  rescue StandardError
    nil
  end

  # Delete a marker. Guarded for the same reason writes are: deleting the
  # operator's live .open-activity is pollution too — it strands the open activity
  # and every action captured after it attributes to nothing.
  def delete(session_id, projects_dir, suffix, env: ENV, state_dir: TaskUsageSandbox.real_state_dir)
    path = write_path(session_id, projects_dir, suffix, env: env, state_dir: state_dir)
    File.delete(path) if File.file?(path)
    path
  rescue StandardError
    nil
  end

  # Raw contents of a marker; nil when absent/unreadable. Unguarded — a read
  # cannot pollute the store.
  def read(session_id, projects_dir, suffix)
    path = marker_path(session_id, projects_dir, suffix)
    return nil unless File.file?(path)

    File.read(path)
  rescue StandardError
    nil
  end

  # Walk up from the tool's cwd to the nearest .agent-context.json.
  # nil when cwd is blank, no marker exists, or the file is unreadable/invalid.
  def read_context_marker(cwd)
    dir = cwd.to_s.strip.empty? ? nil : File.expand_path(cwd)
    return nil unless dir

    loop do
      path = File.join(dir, ".agent-context.json")
      return JSON.parse(File.read(path)) if File.file?(path)

      parent = File.dirname(dir)
      return nil if parent == dir

      dir = parent
    end
  rescue StandardError
    nil
  end

  # The per-session active-feature marker (<projects>/.agents/sessions/<id>.json)
  # keyed by the Claude/Codex session id. nil when the id is blank or the marker
  # is absent/unreadable/invalid.
  def read_session_marker(session_id, projects_dir)
    return nil if session_id.to_s.strip.empty?

    raw = read(session_id, projects_dir, ".json")
    return nil unless raw

    JSON.parse(raw)
  rescue StandardError
    nil
  end
end
