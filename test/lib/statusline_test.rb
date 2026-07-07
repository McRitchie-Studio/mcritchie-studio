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

class StatuslineTest < Minitest::Test
  BIN = File.expand_path("../../bin/statusline", __dir__)
  SESSION = "2aa216f6-7565-4bf4-bd01-70793c8ba617" # last 4 = a617

  # Run statusline pointed at a temp worktree context (cwd via the stdin JSON, the
  # real Claude Code shape) so render() runs from a known context file. The
  # context carries ALL fields a real worktree context has (sparse ones trip
  # bash's IFS-whitespace tab collapsing). `session` nil deletes the env var.
  def render_in(session:, extra: {}, provider: :claude)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agent-context.json"), JSON.generate({
        "app" => "mcritchie-studio",
        "worktree_slug" => "session-resume-v1",
        "task_record_slug" => "session-resume-on-tasks",
        "task_url" => "https://mcritchie.studio/tasks/session-resume-on-tasks",
        "stage" => "building"
      }.merge(extra)))
      env = if provider == :codex
              { "CODEX_THREAD_ID" => session, "CLAUDE_CODE_SESSION_ID" => nil }
            else
              { "CLAUDE_CODE_SESSION_ID" => session, "CODEX_THREAD_ID" => nil }
            end
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
      env = if provider == :codex
              { "CODEX_THREAD_ID" => session, "CLAUDE_CODE_SESSION_ID" => nil, "CLAUDE_PROJECTS_DIR" => projects }
            else
              { "CLAUDE_CODE_SESSION_ID" => session, "CODEX_THREAD_ID" => nil, "CLAUDE_PROJECTS_DIR" => projects }
            end
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
  def heartbeat_calls(stage:, runs: 1, session: SESSION, slug: "session-claim-lease-gate")
    Dir.mktmpdir do |dir|
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

      env = {
        "CLAUDE_CODE_SESSION_ID" => session,
        "CODEX_THREAD_ID" => nil,
        "TASK_BIN" => stub,
        "STATUSLINE_HEARTBEAT_FG" => "1",
        "CLAUDE_PROJECTS_DIR" => File.join(dir, "projects")
      }
      stdin = JSON.generate("workspace" => { "current_dir" => dir })
      runs.times { Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL) }

      File.exist?(calls) ? File.read(calls).lines.map(&:strip) : []
    end
  end

  def test_statusline_fires_the_heartbeat_for_the_active_building_task
    calls = heartbeat_calls(stage: "building")
    assert_equal ["heartbeat session-claim-lease-gate"], calls,
                 "a building task's status line should renew its claim via `task heartbeat <slug>`"
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
    assert_equal ["heartbeat session-claim-lease-gate"], heartbeat_calls(stage: ""),
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

      env = {
        "CLAUDE_CODE_SESSION_ID" => session,
        "TASK_BIN" => stub,
        "STATUSLINE_HEARTBEAT_FG" => "1",
        "CLAUDE_PROJECTS_DIR" => projects
      }
      stdin = JSON.generate("workspace" => { "current_dir" => cwd })
      Open3.capture2(env, "/bin/bash", BIN, stdin_data: stdin, err: File::NULL)
      File.exist?(calls) ? File.read(calls).lines.map(&:strip) : []
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
end
