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
# (+write_path+).
#
# THE INVARIANT, stated positively — this is what is actually enforced:
#
#   EVERY filesystem MUTATION of this store passes TaskUsageSandbox.enforce!
#   with store: "session-marker".
#
# Note what that does NOT say: it does not say "goes through SessionMarkers".
# bin/task legitimately hand-rolls its own path and calls enforce! itself, and it
# is fail-closed for doing so. The choke point is the GUARD, not this file.
#
# Two mechanisms hold the invariant, because the first one alone is a convention:
#   1. STRUCTURAL — +marker_path+ is private (see below), so no caller outside this
#      module can get an unguarded marker path from us at all. bin/atomic-event and
#      bin/devops-shift now hold ZERO raw marker paths; there is nothing to misuse.
#      This is not decoration: test/lib/state_store_containment_test.rb's LAYER 2a
#      ASSERTS the builder is private, because a lib that hands out a raw path lets a
#      caller mutate the store without ever naming ".agents" — which no source scan
#      can see, in any spelling.
#   2. STATIC — test/lib/state_store_containment_test.rb re-derives the mutation set
#      from the SOURCE on every run and fails on any method that HOLDS a raw marker
#      path (ours OR a hand-rolled one, in ANY spelling — File.join, interpolation, a
#      constant) without passing enforce!.
#
#      Be precise about WHY that is default-DENY, because the first draft of that test
#      claimed this and did not deliver it. It does NOT work by recognising the write:
#      it never looks at the write at all. It works on the PRECONDITION — you cannot
#      mutate a path you never named — so a seventh writer invented years from now is
#      refused for HOLDING the path, whether it reaches for File.write, Pathname#delete,
#      File.binwrite, or `system("rm …")`. There is no list of IO verbs to keep current,
#      which is exactly what the old version got wrong: it had one, a shell-out was
#      invisible to it by construction, and an ordinary interpolated path walked past it
#      GREEN. The rule is enforced against the tree, not against this comment.
#
# WHO ELSE TOUCHES THIS STORE, precisely — do not let this list rot (the
# containment test above will catch you if you do):
#   bin/task           WRITES <id>.json. Resolves its own path (PROJECTS_DIR is a
#                      load-time constant off ENV) but guards it at the SAME
#                      TaskUsageSandbox seam (bin/task:631, :1139), so it is
#                      fail-closed already.
#   bin/statusline     WRITES the .heartbeat/.shift-heartbeat throttles. Bash, so
#                      it cannot call this module; it enforces rule 1 inline and
#                      leans on the Ruby CLIs it shells for rule 2 (see its header).
#   bin/agent-marker,  READ-only. Unguarded on purpose: a read cannot pollute — so
#   bin/atomic-capture-hook  agent-marker resolving its own read path by hand is
#                      allowed. Each such method is named, with its reason, in the
#                      containment test's UNGUARDED_PATH_METHODS — a closed list of
#                      methods, NOT a list of permitted IO verbs.
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
  #
  # PRIVATE, and that is the point. An UNGUARDED path builder sitting next to a
  # guarded write API is an attractive nuisance: a caller reaches for the path,
  # does its own File.write/File.delete, and silently rejoins the population this
  # module exists to empty. That is not hypothetical — it is exactly how
  # bin/atomic-event#clear_activity_usage_baselines came to raw-File.delete the
  # operator's live .activity-usage.json on the common close path (PR #549 review),
  # while its guarded sibling clear_acting_agent did the same job correctly. So the
  # builder is reachable only from INSIDE this module, and the only exported way to
  # name a marker for MUTATION is write/delete — both of which enforce.
  #
  # A test that needs to assert on a path may `send(:marker_path, …)`: a deliberate,
  # greppable reach into the internals, not an accident a writer can fall into.
  def marker_path(session_id, projects_dir, suffix)
    safe = session_id.to_s.gsub(/[^A-Za-z0-9._-]/, "")
    File.join(projects_dir.to_s, ".agents", "sessions", "#{safe}#{suffix}")
  end
  private_class_method :marker_path

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

  # The env the guard is evaluated against: the PIN from the caller's injected env,
  # the ARMING from the process ENV — so `AgentActivityCli.new(env: {})` cannot
  # disarm the guard by omission. It lives on TaskUsageSandbox now because the token
  # cache (bin/lib/agent_api.rb) needs the identical split; see its rationale there.
  def guard_env(env) = TaskUsageSandbox.guard_env(env)

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
