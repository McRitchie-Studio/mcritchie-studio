# frozen_string_literal: true

# Standalone test for bin/statusline's session-resume segment. Runs the script
# under /bin/bash (macOS bash 3.2 — proves the portable last-4 expansion works
# there) with a temp worktree context, and asserts the …<last4> is appended when
# CLAUDE_CODE_SESSION_ID is set and omitted when it is not.
#
#   ruby -Itest test/lib/statusline_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "socket"
require_relative "../support/session_env"

class StatuslineTest < Minitest::Test
  BIN = File.expand_path("../../bin/statusline", __dir__)
  TASK_CLI = File.expand_path("../../bin/task", __dir__) # the real CLI, for the boundary test
  SESSION = "2aa216f6-7565-4bf4-bd01-70793c8ba617" # last 4 = a617

  # The env var that names a session for `provider`. Pair it with
  # SessionEnv.neutralized and the OTHER provider's var is unset for free — these
  # tests assert per-provider resolution, so exactly one may ever be set.
  def session_key(provider)
    provider == :codex ? "CODEX_THREAD_ID" : "CLAUDE_CODE_SESSION_ID"
  end

  # Run statusline pointed at a temp worktree context (cwd via the stdin JSON, the
  # real Claude Code shape) so render() runs from a known context file. The
  # context carries ALL fields a real worktree context has (sparse ones trip
  # bash's IFS-whitespace tab collapsing). `session` nil deletes the env var.
  #
  # PINNED (this used to be the leak). The context below says stage "building", so
  # every render here also fires heartbeat_claim — and this helper pinned NEITHER
  # CLAUDE_PROJECTS_DIR nor HOME, so `${CLAUDE_PROJECTS_DIR:-$HOME/projects}`
  # resolved to the OPERATOR'S REAL store: each suite run re-wrote a 0-byte
  # `<session>.heartbeat` into ~/projects/.agents/sessions and shelled the REAL
  # bin/task heartbeat at the production board, detached. Now the roots are pinned
  # at a tmpdir (TaskUsageSandboxEnv.child_env) and TASK_BIN is a no-op stub, so
  # these render assertions can never reach the operator's state or the board.
  #
  # AND THE SLUG IS FICTIONAL. It used to name a REAL production task
  # ("session-resume-on-tasks"), so for the ~3 weeks the leak was live every unpinned
  # render fired `bin/task heartbeat` at that real task on the real board. A fixture
  # that names a live record turns any escape into a targeted write. The pins above
  # are what CONTAIN the blast; a fictional slug is what makes the blast harmless if a
  # pin is ever missed again. Keep it fictional — belt and braces, deliberately.
  def render_in(session:, extra: {}, provider: :claude)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), JSON.generate({
        "app" => "mcritchie-studio",
        "worktree_slug" => "fixture-worktree-slug",
        "task_record_slug" => "fixture-task-slug",
        "task_url" => "https://mcritchie.studio/tasks/fixture-task-slug",
        "stage" => "building"
      }.merge(extra)))
      # Exactly ONE session var set — SessionEnv unsets the other for us, so the
      # provider under test is the only one bin/statusline can resolve.
      env = SessionEnv.neutralized(
        TaskUsageSandboxEnv.child_env(dir).merge(
          session_key(provider) => session,
          "TASK_BIN" => "/usr/bin/true"
        )
      )
      stdin = JSON.generate("workspace" => { "current_dir" => dir })
      out, = Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL)
      out
    end
  end

  def render_session_marker_in(session:, extra: {}, provider: :codex)
    Dir.mktmpdir do |projects|
      sessions = File.join(projects, ".agents", "sessions")
      FileUtils.mkdir_p(sessions)
      File.write(File.join(sessions, "#{session}.json"), JSON.generate({
        "app" => "mcritchie-studio",
        "mascot" => "arcanine",
        "mascot_color" => "#EE8130",
        "mascot_emoji" => "🔥"
      }.merge(extra)))
      # TASK_BIN stubbed exactly like render_in's, and for the same reason (the
      # header above). A marker carrying a task slug AND stage "building" makes
      # heartbeat_claim shell out; the CLAUDE_PROJECTS_DIR pin contains the marker
      # WRITE but NOT the board REQUEST, so the pin alone is one brace of the two
      # this file requires. Any fixture here may set stage — keep the stub.
      env = SessionEnv.neutralized(session_key(provider) => session,
                                   "CLAUDE_PROJECTS_DIR" => projects,
                                   "TASK_BIN" => "/usr/bin/true")
      stdin = JSON.generate("workspace" => { "current_dir" => projects })
      out, = Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL)
      out
    end
  end

  def test_appends_session_last4_when_session_is_set
    out = render_in(session: SESSION)
    assert_includes out, "…a617", "status line should append the session last-4"
    assert_includes out, "[building]", "the stage segment should still render"
  end

  def test_omits_session_last4_when_no_session
    out = render_in(session: nil)
    refute_includes out, "…a617", "no session → no last-4 segment"
    assert_includes out, "[building]", "the no-session path must still render the stage"
  end

  def test_reads_codex_session_marker
    out = render_session_marker_in(session: SESSION, provider: :codex)
    assert_includes out, "🔥", "the Codex marker's type emoji leads"
    assert_includes out, "Arcanine"
    assert_includes out, "mcritchie-studio"
    assert_includes out, "…a617", "Codex thread id gets the same last-4 suffix"
  end

  # --- Genesis bearing: the session's write-once first task leads the feature --

  # A session that has moved on to a different task shows BOTH: the genesis it was
  # spun up for, then the task it is touching — "why I exist ▸ what I'm touching".
  def test_session_marker_shows_genesis_beside_a_different_current_task
    out = render_session_marker_in(session: SESSION, extra: {
      "worktree_slug" => "current-fixture-fix", "task_slug" => "current-fixture-fix",
      "stage" => "building",
      "genesis_slug" => "origin-fixture-task", "genesis_feature" => "origin-fixture-task"
    })
    assert_includes out, "origin-fixture-task ▸ current-fixture-fix",
                    "the genesis leads the feature segment"
  end

  # Same task → the segment renders exactly as before, no arrow.
  def test_genesis_is_silent_when_it_is_the_current_task
    out = render_session_marker_in(session: SESSION, extra: {
      "worktree_slug" => "origin-fixture-task", "task_slug" => "origin-fixture-task",
      "stage" => "building",
      "genesis_slug" => "origin-fixture-task", "genesis_feature" => "origin-fixture-task"
    })
    assert_includes out, "origin-fixture-task"
    refute_includes out, "▸", "no arrow when the session is still on its genesis task"
  end

  # A marker with no genesis fields (every marker written before this feature,
  # and every worktree desk context) renders exactly as before.
  def test_no_genesis_fields_render_unchanged
    out = render_session_marker_in(session: SESSION, extra: {
      "worktree_slug" => "current-fixture-fix", "task_slug" => "current-fixture-fix"
    })
    assert_includes out, "current-fixture-fix"
    refute_includes out, "▸"
  end

  # --- Mascot tint: the <mascot> name wears its least-common type color --------

  def test_mascot_handle_is_tinted_with_its_type_color
    # Dragonite's signature (dragon) color #6F35FC → nearest xterm-256 cube = 63.
    # 256-color (not truecolor): the default Terminal.app supports 256, not 24-bit.
    # No type emoji here → the tint lands on the bare name (no ⊙ glyph).
    out = render_in(session: SESSION, extra: { "mascot" => "dragonite", "mascot_color" => "#6F35FC" })
    assert_includes out, "\e[38;5;63mDragonite", "the name wears the type's 256-color"
    refute_includes out, "⊙", "no ⊙ glyph — the name stands on its own"
    refute_includes out, "[38;2;", "no 24-bit truecolor (unsupported in Terminal.app)"
  end

  def test_mascot_falls_back_to_neutral_tint_without_a_color_never_pink
    out = render_in(session: SESSION, extra: { "mascot" => "snorlax" })
    assert_includes out, "\e[38;5;250mSnorlax", "no color → the neutral default tint on the name"
    refute_includes out, "\e[38;5;213m", "never the old pink mascot default (213)"
  end

  # Even with an EMPTY middle field (no task_url), the mascot_color must still
  # land on the mascot — the US-separator join keeps fields from shifting.
  def test_mascot_color_survives_a_sparse_context
    # Bug #A6B91A → nearest xterm-256 cube = 142.
    out = render_in(session: SESSION, extra: {
      "task_url" => "", "mascot" => "parasect", "mascot_color" => "#A6B91A"
    })
    assert_includes out, "\e[38;5;142mParasect", "bug 256-color lands on the name despite the empty url field"
    refute_includes out, "⊙", "no ⊙ glyph"
  end

  # --- Mascot type emoji: leads + replaces the 🛠 ⊙ glyphs ----------------------

  def test_mascot_type_emoji_replaces_the_tool_and_dot
    out = render_in(session: SESSION, extra: {
      "mascot" => "dugtrio", "mascot_color" => "#E2BF65", "mascot_emoji" => "🏔"
    })
    assert_includes out, "🏔", "the type emoji leads the mascot handle"
    assert_includes out, "Dugtrio"
    refute_includes out, "⊙", "the ⊙ dot is dropped when a type emoji is present"
    refute_includes out, "🛠", "and the 🛠 is replaced by the type emoji"
  end

  def test_dual_type_mascot_leads_with_both_emojis
    out = render_in(session: SESSION, extra: {
      "mascot" => "charizard", "mascot_color" => "#A98FF3", "mascot_emoji" => "🔥💨"
    })
    assert_includes out, "🔥💨", "both type emojis lead"
    assert_includes out, "Charizard"
  end

  def test_shiny_mascot_adds_sparkle_after_type_emoji
    out = render_in(session: SESSION, extra: {
      "mascot" => "dugtrio", "mascot_color" => "#E2BF65",
      "mascot_emoji" => "🏔", "mascot_shiny" => true
    })
    assert_includes out, "🏔✨", "the shiny glyph rides next to the type emoji"
    assert_includes out, "\e]0;🏔✨ Dugtrio\a", "the tab title gets the same shiny marker"
  end

  def test_shiny_mascot_normalizes_legacy_prefixed_sparkle
    out = render_in(session: SESSION, extra: {
      "mascot" => "dugtrio", "mascot_color" => "#E2BF65", "mascot_emoji" => "✨🏔"
    })
    assert_includes out, "🏔✨", "legacy prefix form is normalized in the status line"
    refute_includes out, "✨🏔 Dugtrio"
  end

  def test_explicit_non_shiny_marker_clears_legacy_sparkle
    out = render_in(session: SESSION, extra: {
      "mascot" => "dugtrio", "mascot_color" => "#E2BF65",
      "mascot_emoji" => "🏔✨", "mascot_shiny" => false
    })
    assert_includes out, "🏔", "the type emoji still renders"
    refute_includes out, "🏔✨", "explicit false clears a stale shiny marker"
  end

  def test_mascot_without_an_emoji_renders_clean_name_not_pink_fallback
    # The reported bug: a board-served mascot with no color/emoji rendered the pink
    # "🛠 ⊙ <name>". Now it's just the name in the neutral tint — never the glyphs.
    out = render_in(session: SESSION, extra: { "mascot" => "snorlax" })
    assert_includes out, "Snorlax", "the name still renders"
    refute_includes out, "⊙", "no ⊙ dot"
    refute_includes out, "🛠", "no tool glyph"
    refute_includes out, "\e[38;5;213m", "and never the old pink tint"
  end

  # --- Heartbeat wiring (V2): the status line renews the active build claim ----

  # Run statusline with a stub `task` binary (records its args) wired in via
  # TASK_BIN, in foreground heartbeat mode so the call is observable. Returns the
  # recorded invocations (one per line, e.g. "heartbeat <slug>").
  # @heartbeat_desk records the directory the render ran in, so a case can assert
  # that the desk handed to `bin/task heartbeat` is THAT directory and not some
  # other checkout — the distinction the whole desk-keyed lease rests on.
  attr_reader :heartbeat_desk

  def heartbeat_calls(stage:, runs: 1, session: SESSION, slug: "session-claim-lease-gate")
    Dir.mktmpdir do |dir|
      @heartbeat_desk = dir
      File.write(File.join(dir, ".agent-context.json"), JSON.generate(
        "app" => "mcritchie-studio",
        "worktree_slug" => "session-claim-lease-gate",
        "task_record_slug" => slug,
        "task_url" => "https://mcritchie.studio/tasks/#{slug}",
        "stage" => stage
      ))
      calls = File.join(dir, "calls.log")
      stub = File.join(dir, "task")
      File.write(stub, "#!/bin/bash\necho \"$@\" >> #{calls.inspect}\n")
      File.chmod(0o755, stub)

      env = SessionEnv.neutralized(
        "CLAUDE_CODE_SESSION_ID" => session,
        "TASK_BIN" => stub,
        "STATUSLINE_HEARTBEAT_FG" => "1",
        "CLAUDE_PROJECTS_DIR" => File.join(dir, "projects")
      )
      stdin = JSON.generate("workspace" => { "current_dir" => dir })
      runs.times { Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL) }

      File.exist?(calls) ? File.read(calls).lines.map(&:strip) : []
    end
  end

  # The status line renews the claim — and, since 2026-08-13, hands over the DESK
  # it is rendering in so the renewal is decided on evidence of work rather than on
  # evidence that this status line is painting. Without the desk, an open terminal
  # renews a build claim forever (bin/task falls back to "unknown", which never
  # frees a claim), which is exactly the stall this fix exists to end.
  def test_statusline_fires_the_heartbeat_for_the_active_building_task
    calls = heartbeat_calls(stage: "building")
    assert_equal ["heartbeat session-claim-lease-gate --desk #{heartbeat_desk}"], calls,
                 "a building task's status line should renew its claim via `task heartbeat <slug> --desk <desk>`"
  end

  def test_statusline_throttles_repeated_heartbeats
    calls = heartbeat_calls(stage: "building", runs: 3)
    assert_equal 1, calls.size, "the throttle suppresses repeat heartbeats within the window"
  end

  def test_statusline_does_not_heartbeat_a_non_building_task
    assert_empty heartbeat_calls(stage: "submitted"),
                 "only the live BUILD claim is renewed — other stages don't heartbeat"
  end

  def test_statusline_does_not_heartbeat_without_a_session
    assert_empty heartbeat_calls(stage: "building", session: nil),
                 "no session → no claim to renew"
  end

  # A WORKTREE build desk legitimately carries no stage (.agent-context.json is
  # written with stage:nil → ""). Its claim must STILL renew — the empty-stage
  # renew is load-bearing for worktrees and must not regress.
  def test_statusline_still_heartbeats_an_empty_stage_worktree_desk
    calls = heartbeat_calls(stage: "")

    assert_equal ["heartbeat session-claim-lease-gate --desk #{heartbeat_desk}"], calls,
                 "an empty-stage worktree desk is a real build — its claim renews"
  end

  # --- Per-session marker: filing/owning a task is NOT a build desk -----------

  # The per-session marker (sessions/<id>.json, where `bin/task create` writes) is
  # display context, NOT a build desk. Run statusline with that marker as the only
  # source — a cwd WITHOUT a worktree .agent-context.json — and a stub `task` that
  # records its invocations. Returns the recorded `task` calls.
  def session_marker_heartbeat_calls(stage:, session: SESSION, slug: "skip-self-claim-demo")
    Dir.mktmpdir do |dir|
      projects = File.join(dir, "projects")
      FileUtils.mkdir_p(File.join(projects, ".agents", "sessions"))
      File.write(File.join(projects, ".agents", "sessions", "#{session}.json"), JSON.generate(
        "app" => "mcritchie-studio",
        "worktree_slug" => slug,
        "task_slug" => slug,
        "task_url" => "https://mcritchie.studio/tasks/#{slug}",
        "stage" => stage
      ))
      cwd = File.join(dir, "cwd") # NO .agent-context.json → src falls to the session marker
      FileUtils.mkdir_p(cwd)
      calls = File.join(dir, "calls.log")
      stub = File.join(dir, "task")
      File.write(stub, "#!/bin/bash\necho \"$@\" >> #{calls.inspect}\n")
      File.chmod(0o755, stub)

      # This one previously forgot CODEX_THREAD_ID => nil, so a Codex agent running
      # the suite leaked its thread into the child. SessionEnv unsets it by default.
      env = SessionEnv.neutralized(
        "CLAUDE_CODE_SESSION_ID" => session,
        "TASK_BIN" => stub,
        "STATUSLINE_HEARTBEAT_FG" => "1",
        "CLAUDE_PROJECTS_DIR" => projects
      )
      stdin = JSON.generate("workspace" => { "current_dir" => cwd })
      Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL)
      # HEARTBEAT calls only — the helper's name is its contract. These fixtures
      # carry no mascot, so every render here also (correctly) fires the mascot
      # self-heal; asserting "no calls at all" would make these gates fail on an
      # unrelated, working feature. Assert the heartbeat, not the quiet.
      raw = File.exist?(calls) ? File.read(calls).lines.map(&:strip) : []
      raw.grep(/\Aheartbeat\b/)
    end
  end

  # The bug: `bin/task create` repoints the creator's per-session marker to the new
  # `designed` task; the heartbeat then forged a live build-claim on a task nobody
  # was building (the creator's mascot ticking green on an unowned task).
  def test_statusline_does_not_heartbeat_a_designed_session_marker
    assert_empty session_marker_heartbeat_calls(stage: "designed"),
                 "a freshly-filed `designed` task in the per-session marker must not forge a claim"
  end

  # The empty-stage loophole, scoped: a per-session marker with no stage (a create
  # response that omitted it) is NOT a build desk — it must not renew.
  def test_statusline_does_not_heartbeat_an_empty_stage_session_marker
    assert_empty session_marker_heartbeat_calls(stage: ""),
                 "an empty/missing stage in the per-session marker is not a build desk"
  end

  # A REAL builder claim (`move building`) from the primary checkout writes the
  # per-session marker with stage=building — that still renews, filling the slot.
  def test_statusline_heartbeats_a_building_session_marker
    assert_equal ["heartbeat skip-self-claim-demo"], session_marker_heartbeat_calls(stage: "building"),
                 "a real move→building claim still renews from the per-session marker"
  end

  # --- Session-mascot self-heal ------------------------------------------------

  # The SessionStart hook draws the mascot by POSTing the board, and bin/task wraps
  # that draw in `rescue SystemExit, StandardError` so a session never fails to
  # start. A board that is briefly unreachable therefore writes NO marker, logs
  # nothing, and leaves the status line on its repo/branch fallback — the operator
  # is the only detector. The render heals it: no mascot yet → redraw, throttled and
  # detached exactly like the two heartbeats above.
  #
  # Run statusline with a stub `task` and return the recorded invocations. `marker:`
  # is the sessions/<id>.json payload (nil writes none at all — the hook-failed
  # case); `desk: true` also drops a worktree .agent-context.json in the cwd. The
  # fixtures deliberately carry NO task slug, so heartbeat_claim returns early and
  # every recorded call belongs to the heal.
  # A `stat` that behaves like GNU coreutils, so the macOS-only throttle clock can be
  # exercised here on the shape CI actually runs. GNU reads `-f` as `--file-system`,
  # so `%m` is not a format — it is a second FILE OPERAND. GNU errors on it (stderr,
  # nonzero exit) and still prints a MULTI-LINE filesystem block for the real path on
  # stdout, which is the junk that reaches $(( )) as a fatal expansion error.
  # Returns the dir to prepend to PATH.
  def gnu_stat_shim(dir)
    bin = File.join(dir, "shim")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "stat"), <<~SH)
      #!/bin/bash
      if [ "$1" = "-f" ]; then
        shift
        for arg in "$@"; do
          if [ "$arg" = "%m" ]; then
            echo "stat: cannot read file system information for '%m': No such file or directory" >&2
          else
            printf '  File: "%s"\\n    ID: 0 Namelen: 255 Type: ext2/ext3\\nBlock size: 4096\\n' "$arg"
          fi
        done
        exit 1
      fi
      if [ "$1" = "-c" ] && [ "$2" = "%Y" ]; then
        /usr/bin/stat -c %Y "$3" 2>/dev/null || /usr/bin/stat -f %m "$3"
        exit $?
      fi
      exec /usr/bin/stat "$@"
    SH
    FileUtils.chmod(0o755, File.join(bin, "stat"))
    bin
  end

  def mascot_heal_calls(marker: nil, desk: false, session: SESSION, runs: 1, throttle: nil, gnu_stat: false)
    Dir.mktmpdir do |dir|
      projects = File.join(dir, "projects")
      FileUtils.mkdir_p(File.join(projects, ".agents", "sessions"))
      File.write(File.join(projects, ".agents", "sessions", "#{session}.json"), JSON.generate(marker)) if marker
      cwd = File.join(dir, "cwd")
      FileUtils.mkdir_p(cwd)
      if desk
        File.write(File.join(cwd, ".agent-context.json"), JSON.generate(
          "app" => "mcritchie-studio", "worktree_slug" => "desk-fixture", "stage" => ""
        ))
      end
      calls = File.join(dir, "calls.log")
      stub = File.join(dir, "task")
      File.write(stub, "#!/bin/bash\necho \"$@\" >> #{calls.inspect}\n")
      File.chmod(0o755, stub)

      env = SessionEnv.neutralized(
        "CLAUDE_CODE_SESSION_ID" => session,
        "TASK_BIN" => stub,
        "STATUSLINE_HEARTBEAT_FG" => "1",
        "CLAUDE_PROJECTS_DIR" => projects,
        "STATUSLINE_MASCOT_HEAL_THROTTLE" => throttle,
        "PATH" => (gnu_stat ? "#{gnu_stat_shim(dir)}:#{ENV.fetch('PATH')}" : ENV.fetch("PATH"))
      )
      stdin = JSON.generate("workspace" => { "current_dir" => cwd })
      runs.times { Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL) }
      File.exist?(calls) ? File.read(calls).lines.map(&:strip) : []
    end
  end

  def test_statusline_heals_a_missing_session_mascot
    assert_equal ["session-mascot"], mascot_heal_calls,
                 "no marker at all (the hook's silent failure) must redraw the session mascot"
  end

  # Same hole, different shape: `bin/task create` wrote the marker but the board
  # served no mascot with it. The heal MERGES into the existing marker, so this
  # converges rather than looping.
  def test_statusline_heals_a_session_marker_carrying_no_mascot
    assert_equal ["session-mascot"],
                 mascot_heal_calls(marker: { "app" => "mcritchie-studio" }),
                 "a marker written without a mascot is the same hole — redraw it"
  end

  def test_statusline_does_not_heal_an_already_drawn_mascot
    assert_empty mascot_heal_calls(marker: { "app" => "mcritchie-studio", "mascot" => "entei" }),
                 "the healthy path must stay free — a drawn mascot never redraws"
  end

  # A worktree desk paints from .agent-context.json, but the heal writes the
  # SESSION marker — healing here would never change what renders, so it would
  # re-fire every throttle window forever. Scope it out.
  def test_statusline_does_not_heal_on_a_worktree_desk
    assert_empty mascot_heal_calls(desk: true),
                 "a desk renders its own context; healing the session marker would never converge"
  end

  def test_statusline_does_not_heal_without_a_session
    assert_empty mascot_heal_calls(session: nil),
                 "no session id → no session to draw a mascot for"
  end

  # The failure this heals is a DOWN board. Retrying once per render would turn one
  # outage into a request flood.
  def test_statusline_throttles_the_mascot_heal
    assert_equal 1, mascot_heal_calls(runs: 3).size,
                 "a board that stays down must not be hammered once per render"
  end

  # The throttle marker is stamped BEFORE the attempt, so a heal that FAILS still
  # burns its window — deliberate (that is what rate-limits a down board), but it
  # makes the retry the load-bearing half: the stub here never writes a mascot, so
  # every run is a failed heal. Observed live on 2026-08-08 — the first heal hit a
  # board hiccup and wrote nothing, and only the retry put the mascot back.
  def test_statusline_retries_a_failed_heal_once_the_window_expires
    assert_equal 3, mascot_heal_calls(runs: 3, throttle: "0").size,
                 "a heal that wrote no mascot must try again — one shot is not a heal"
  end

  # The throttle clock was macOS-only (`stat -f %m`), and its Linux failure was not
  # "the throttle misbehaves" — the junk GNU prints for that spelling reaches
  # $(( )) as a FATAL expansion error, so the whole render dies. On CI the heal
  # therefore fired exactly once (the first render, before any throttle marker
  # existed) and every later render was killed before reaching it: PR #734's `test`
  # job, expected 3, got 1.
  #
  # Note what this means for the throttle tests ABOVE: a crashed render produces the
  # same call count as a working throttle, so they stayed green on Linux for three
  # weeks while the script was aborting. Counting calls cannot tell those apart —
  # only forcing the window OPEN can, because then the count and the crash disagree.
  def test_heal_survives_a_gnu_stat_and_still_retries
    assert_equal 3, mascot_heal_calls(runs: 3, throttle: "0", gnu_stat: true).size,
                 "the throttle clock must read an mtime on GNU too — not kill the render"
  end

  # --- Self-heal across its I/O boundary (integration) -------------------------

  # The cases above stub TASK_BIN, so they prove the RENDER's decision to heal but
  # not that a heal lands anything. This one drives the REAL bin/task against a fake
  # board (the external edge, mocked) and asserts what the operator actually sees:
  # the marker gains a mascot, and the NEXT render paints it — which is also the
  # convergence proof, since a heal that never satisfies its own trigger would loop.
  def test_heal_draws_the_mascot_through_the_real_cli
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    seen = []
    thread = Thread.new do
      begin
        loop do
          client = server.accept
          line = client.gets
          (client.close; next) if line.nil?
          method, path, = line.split(" ")
          headers = {}
          while (h = client.gets) && h != "\r\n"
            k, v = h.split(":", 2)
            headers[k.strip.downcase] = v.strip if v
          end
          client.read(headers["content-length"].to_i) if headers["content-length"]
          seen << "#{method} #{path}"
          payload = if path == "/api/v1/auth"
                      JSON.generate("token" => "stub-token")
                    else
                      JSON.generate("data" => { "mascot" => "entei", "mascot_color" => "#EE8130",
                                                "mascot_emoji" => "🔥", "app" => "mcritchie-studio" })
                    end
          client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                       "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
          client.close
        end
      rescue IOError, Errno::EBADF, Errno::ECONNRESET
        nil
      end
    end

    Dir.mktmpdir do |dir|
      # child_env pins CLAUDE_PROJECTS_DIR (and HOME, and the cost store) at <dir>/projects
      # — the same pin the heal's marker write is sandbox-gated on.
      pins = TaskUsageSandboxEnv.child_env(dir)
      marker = File.join(pins.fetch("CLAUDE_PROJECTS_DIR"), ".agents", "sessions", "#{SESSION}.json")
      cwd = File.join(dir, "cwd")
      FileUtils.mkdir_p(cwd) # no .agent-context.json → not a desk
      refute_path_exists marker, "precondition: the SessionStart hook left no mascot behind"

      env = SessionEnv.neutralized(pins.merge(
        "CLAUDE_CODE_SESSION_ID" => SESSION,
        "TASK_BIN" => TASK_CLI,
        "STATUSLINE_HEARTBEAT_FG" => "1",
        "TASK_API_BASE" => "http://127.0.0.1:#{port}",
        "AGENT_API_SECRET" => "test-secret"
      ))
      stdin = JSON.generate("workspace" => { "current_dir" => cwd })

      first, = Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL)
      refute_includes first, "Entei", "the render that DISCOVERS the hole still paints the fallback"

      assert_includes seen, "POST /api/v1/sessions/#{SESSION}/mascot",
                      "the heal must reach the board's session-mascot endpoint"
      assert_path_exists marker, "the heal must write the marker the status line reads"
      assert_equal "entei", JSON.parse(File.read(marker))["mascot"]

      second, = Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL)
      assert_includes second, "Entei", "the next render paints the healed mascot"
      assert_equal 1, seen.count { |r| r.start_with?("POST /api/v1/sessions") },
                   "and does not redraw it — one heal, then quiet"
    end
  ensure
    server&.close
    thread&.join(1)
  end

  # --- App slug tint: each app wears its App#color (MS lavender, TM green, …) ----

  def test_app_slug_is_tinted_with_its_app_color
    # Turf Monster green #22C55E → nearest xterm-256 cube = 41 (256-color, not 24-bit).
    out = render_in(session: SESSION, extra: { "app" => "turf-monster", "app_color" => "#22C55E" })
    assert_includes out, "\e[38;5;41mturf-monster", "the app slug wears its App#color 256-color"
    refute_includes out, "[38;2;", "no 24-bit truecolor (unsupported in Terminal.app)"
  end

  def test_app_slug_falls_back_to_default_tint_without_a_color
    out = render_in(session: SESSION, extra: { "app" => "mcritchie-studio" })
    assert_includes out, "\e[38;5;75mmcritchie-studio", "no app_color → the default app tint (75)"
  end

  # --- Terminal tab title (OSC 0): emoji then name, set live from the status line -

  def test_emits_osc_tab_title_emoji_then_name
    out = render_in(session: SESSION, extra: {
      "mascot" => "golem", "mascot_emoji" => "🗿🏔", "mascot_color" => "#B6A136"
    })
    assert_includes out, "\e]0;🗿🏔 Golem\a", "the tab title leads with the type emoji then the name"
  end

  def test_osc_tab_title_for_an_agent_persona
    # A persona stamps the agent NAME as the mascot + the agent's glyph/tint.
    out = render_in(session: SESSION, extra: {
      "mascot" => "Jasper", "mascot_emoji" => "🧪", "mascot_color" => "#9945FF"
    })
    assert_includes out, "\e]0;🧪 Jasper\a", "acting as a soul sets the tab to its glyph + name"
    assert_includes out, "🧪 ", "and the persona leads the in-pane line too"
  end

  def test_no_osc_tab_title_without_a_mascot
    out = render_in(session: SESSION, extra: { "app" => "mcritchie-studio" })
    refute_includes out, "\e]0;", "no mascot → no tab-title override (don't fight the terminal)"
  end

  # --- [integration] the narration-marker sandbox (bash half) ------------------
  #
  # THE ESCAPE THIS PINS, exactly as it happened. bin/statusline resolves its
  # marker root as `${CLAUDE_PROJECTS_DIR:-$HOME/projects}`. A test process arms
  # TASK_USAGE_SANDBOX (test/support/task_usage_sandbox.rb, inherited by every
  # child) but pinned NEITHER var here — so the fallback landed in the OPERATOR'S
  # REAL ~/projects/.agents/sessions, where a 0-byte `<session>.heartbeat` was
  # re-written on every suite run, and the REAL `bin/task heartbeat` fired at the
  # production board behind it. Cross-session marker pollution mis-attributes
  # activities to the wrong task — the narration timeline the learning loop reads.
  #
  # The vector is reproduced SAFELY: HOME is pinned at a tmpdir, so an unguarded
  # statusline writes THERE (provably — the guarded one writes nowhere) instead of
  # in the operator's store. Assert on the fallback root, never on the real one.
  def unpinned_sandboxed_run(stage: "building", armed: "1")
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      FileUtils.mkdir_p(home)
      File.write(File.join(dir, ".agent-context.json"), JSON.generate(
        "app" => "mcritchie-studio", "worktree_slug" => "guard-narration-marker-writes",
        "task_record_slug" => "guard-narration-marker-writes",
        "task_url" => "https://mcritchie.studio/tasks/guard-narration-marker-writes", "stage" => stage
      ))
      calls = File.join(dir, "calls.log")
      stub = File.join(dir, "task")
      File.write(stub, "#!/bin/bash\necho \"$@\" >> #{calls.inspect}\n")
      File.chmod(0o755, stub)

      # The leak's exact shape: sandbox ARMED, CLAUDE_PROJECTS_DIR UNSET (nil ⇒ the
      # child does not export it at all), HOME redirected so the fallback is visible.
      env = SessionEnv.neutralized(
        "CLAUDE_CODE_SESSION_ID" => SESSION,
        "CLAUDE_PROJECTS_DIR" => nil,
        "TASK_USAGE_SANDBOX" => armed,
        "HOME" => home,
        "TASK_BIN" => stub,
        "STATUSLINE_HEARTBEAT_FG" => "1"
      )
      stdin = JSON.generate("workspace" => { "current_dir" => dir })
      out, err, = Open3.capture3(env, "/bin/bash", BIN, stdin_data: stdin)

      { out: out, err: err,
        markers: Dir.glob(File.join(home, "projects", ".agents", "sessions", "*")),
        calls: File.exist?(calls) ? File.read(calls).lines.map(&:strip) : [] }
    end
  end

  # A refusal must be AUDIBLE. The Ruby half aborts loudly; a silent bash `return 0`
  # is indistinguishable from "nothing happened" — so if TASK_USAGE_SANDBOX ever leaked
  # into the operator's interactive shell, every render would quietly stop renewing both
  # the build claim and the shift lease, with nothing to tell them why.
  def test_integration_a_sandboxed_unpinned_statusline_says_why_it_refused
    run = unpinned_sandboxed_run

    assert_match(/TASK_USAGE_SANDBOX/, run[:err], "the refusal must name the var that armed it")
    assert_match(/CLAUDE_PROJECTS_DIR/, run[:err], "and the var that would have pinned it")
    refute_empty run[:out], "and the status line must STILL RENDER — we fail the write, not the caller"
  end

  # Parity with the Ruby half, which compares against FALSEY after value.downcase. A
  # bash `case` is case-sensitive, so a hand-listed spelling set diverged: "False" read
  # as ARMED in bash and DISARMED in Ruby. Both directions were safe; two halves of one
  # guard disagreeing about whether they are on is not.
  def test_integration_the_bash_falsey_list_matches_rubys_case_insensitively
    %w[False OFF No 0].each do |off|
      run = unpinned_sandboxed_run(armed: off)

      refute_empty run[:markers],
                   "#{off.inspect} must read as DISARMED in bash exactly as it does in Ruby — " \
                   "with the guard off, an unpinned render writes its marker as it always did"
    end
  end

  def test_integration_a_sandboxed_unpinned_statusline_writes_no_marker
    run = unpinned_sandboxed_run
    assert_empty run[:markers],
                 "a sandboxed run that cannot prove its marker destination must write NOTHING — " \
                 "not fall back to <projects>/.agents/sessions"
  end

  # The other half of the same escape: the marker is only a THROTTLE for a real
  # board call. Refusing the write must refuse the lease renewal with it, or the
  # suite still heartbeats the production board on a live task slug.
  def test_integration_a_sandboxed_unpinned_statusline_does_not_renew_the_claim
    assert_empty unpinned_sandboxed_run[:calls],
                 "no provable marker destination → no board heartbeat either"
  end

  # NON-FATAL, the load-bearing counterweight: narration must never block an
  # agent's real work. The guard fails the WRITE, not the CALLER — the status line
  # still renders in full.
  def test_integration_the_marker_guard_never_kills_the_status_line
    out = unpinned_sandboxed_run[:out]
    assert_includes out, "mcritchie-studio", "the status line still renders when the marker write is refused"
    assert_includes out, "…#{SESSION[-4..]}", "and still resolves the session — only the WRITE is refused"
  end

  # And the happy path it must NOT break: a sandboxed run that IS pinned writes its
  # marker and renews normally. A guard that fails closed on the happy path is
  # worse than the bug — the six heartbeat_calls tests above ride on this.
  def test_integration_a_sandboxed_but_pinned_statusline_still_heartbeats
    calls = heartbeat_calls(stage: "building")

    assert_equal ["heartbeat session-claim-lease-gate --desk #{heartbeat_desk}"], calls,
                 "pinned at a tmpdir, the destination is provable — narration works normally under test"
  end
end
