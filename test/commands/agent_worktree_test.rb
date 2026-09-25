require "test_helper"
require "erb"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "socket"
require "tmpdir"
require "uri"
require "yaml"
require_relative "../support/agent_worktree_fixture"

class AgentWorktreeCommandTest < ActiveSupport::TestCase
  # THE DESK FIXTURE — test/support/agent_worktree_fixture.rb. It stages the throwaway
  # hub and its one worktree, owns setup/teardown, and carries every helper that drives
  # the real bin/agent-worktree against them. Read its header before adding a test here:
  # a new concern that needs nothing from THIS file's containment self-tests should get
  # its own file and include the same module — which is what this file's append-hotspot
  # ceiling has been asking for all along, and what this extraction finally makes free.
  include AgentWorktreeFixture

  test "bind-task records the production task on env and context marker" do
    out, err, status = agent_worktree("bind-task", "mcritchie-studio", @task, "task-abc123")

    assert status.success?, err
    assert_includes out, "task bound"
    env = File.read(File.join(@worktree_dir, ".env.agent-stack"))
    assert_includes env, "TASK_RECORD_SLUG=task-abc123"
    assert_includes env, "TASK_URL=https://mcritchie.studio/tasks/task-abc123"

    context = JSON.parse(File.read(File.join(@worktree_dir, ".agent-context.json")))
    assert_equal "task-abc123", context.fetch("task_record_slug")
    assert_equal "https://mcritchie.studio/tasks/task-abc123", context.fetch("task_url")
  end

  test "context regeneration preserves a mascot the rebuilt values lack" do
    # bind-task provisions .env.agent-stack + .agent-context.json. In the sandbox
    # the devops.mascot fetch returns empty, so TASK_MASCOT is absent — exactly the
    # condition under which a from-scratch context rebuild used to blank the Pokemon
    # (the observed Jigglypuff -> task-link flip-flop on a live worktree).
    agent_worktree!("bind-task", "mcritchie-studio", @task, "task-mascot")

    env_path = File.join(@worktree_dir, ".env.agent-stack")
    refute_includes File.read(env_path), "TASK_MASCOT",
      "premise: the rebuilt stack values must lack the mascot"

    ctx_path = File.join(@worktree_dir, ".agent-context.json")
    context = JSON.parse(File.read(ctx_path))
    context["mascot"] = "pikachu" # a mascot drawn earlier, now only on disk
    File.write(ctx_path, "#{JSON.pretty_generate(context)}\n")

    # `whereami <app> <task>` rewrites the context from load_stack_env (no TASK_MASCOT).
    agent_worktree!("whereami", "mcritchie-studio", @task)

    regenerated = JSON.parse(File.read(ctx_path))
    assert_equal "pikachu", regenerated["mascot"],
      "a context regen must fall back to the on-disk mascot, not blank it"
  end

  test "context regeneration preserves a known mascot color + emoji the board read lacks" do
    # The COLOR/EMOJI analog of the mascot-preservation test above. In the sandbox
    # the devops board reads return empty, so before the fix a context rebuild
    # blanked the color/emoji (→ bin/statusline reverted to the default pink + 🛠 ⊙)
    # even though the name stuck. The display attributes must ride with the name.
    agent_worktree!("bind-task", "mcritchie-studio", @task, "task-mascot-color")

    ctx_path = File.join(@worktree_dir, ".agent-context.json")
    context = JSON.parse(File.read(ctx_path))
    context["mascot"] = "dugtrio"       # last-good name, only on disk
    context["mascot_color"] = "#E2BF65" # …and its color
    context["mascot_emoji"] = "🏔"      # …and its type emoji
    File.write(ctx_path, "#{JSON.pretty_generate(context)}\n")

    agent_worktree!("whereami", "mcritchie-studio", @task)

    regenerated = JSON.parse(File.read(ctx_path))
    assert_equal "dugtrio", regenerated["mascot"], "the name still sticks"
    assert_equal "#E2BF65", regenerated["mascot_color"],
      "and its color rides with the name — not blanked to the default tint"
    assert_equal "🏔", regenerated["mascot_emoji"],
      "and its type emoji rides with the name — not blanked to the 🛠 ⊙ glyphs"
  end

  test "context regeneration preserves a known shiny mascot flag" do
    agent_worktree!("bind-task", "mcritchie-studio", @task, "task-mascot-shiny")

    env_path = File.join(@worktree_dir, ".env.agent-stack")
    env = File.read(env_path)
    env = env.lines.reject { |line| line.start_with?("TASK_MASCOT_SHINY=") }.join
    File.write(env_path, env)

    ctx_path = File.join(@worktree_dir, ".agent-context.json")
    context = JSON.parse(File.read(ctx_path))
    context["mascot"] = "dugtrio"
    context["mascot_emoji"] = "🏔"
    context["mascot_shiny"] = true
    File.write(ctx_path, "#{JSON.pretty_generate(context)}\n")

    agent_worktree!("whereami", "mcritchie-studio", @task)

    regenerated = JSON.parse(File.read(ctx_path))
    assert_equal true, regenerated["mascot_shiny"], "the shiny flag rides with the mascot"
    assert_equal "🏔✨", regenerated["mascot_emoji"], "the context emoji carries the sparkle"
  end

  test "whereami shell output ignores tampered shell content from context file" do
    agent_worktree!("bind-task", "mcritchie-studio", @task, "task-shell")
    path = File.join(@worktree_dir, ".agent-context.json")
    context = JSON.parse(File.read(path))
    context["shell"] = {
      "exports" => ["touch /tmp/agent-worktree-pwned"],
      "title_command" => "touch /tmp/agent-worktree-title-pwned"
    }
    context["terminal_title"] = "bad title; touch /tmp/agent-worktree-title-pwned"
    File.write(path, "#{JSON.pretty_generate(context)}\n")

    out, err, status = agent_worktree("whereami", "--shell", chdir: @worktree_dir)

    assert status.success?, err
    assert_includes out, "export AGENT_CONTEXT_TASK_RECORD=task-shell"
    assert_includes out, "export AGENT_CONTEXT_TASK_URL=https://mcritchie.studio/tasks/task-shell"
    assert_includes out, "printf"
    assert_no_match(%r{touch /tmp/agent-worktree}, out)
  end

  test "shell-hook failure path unsets every context export" do
    out, err, status = agent_worktree("shell-hook", "zsh")

    assert status.success?, err
    %w[
      AGENT_CONTEXT_APP
      AGENT_CONTEXT_TASK
      AGENT_CONTEXT_WORKTREE_SLUG
      AGENT_CONTEXT_TASK_RECORD
      AGENT_CONTEXT_TASK_URL
      AGENT_CONTEXT_PORT
      AGENT_CONTEXT_URL
      AGENT_CONTEXT_TITLE
      AGENT_CONTEXT_BADGE
    ].each do |name|
      assert_includes out, name
    end
  end

  test "snapshot includes bound task fields" do
    agent_worktree!("bind-task", "mcritchie-studio", @task, "task-snapshot")
    registry_path = File.join(@projects_dir, ".agents", "registry.json")

    out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write", env: { "AGENT_WORKTREE_REGISTRY" => registry_path })

    assert status.success?, err
    assert_includes out, "wrote"
    registry = JSON.parse(File.read(registry_path))
    record = registry.fetch("worktrees").find { |item| item.fetch("task") == @task }
    assert_equal "task-snapshot", record.fetch("task_record_slug")
    assert_equal "https://mcritchie.studio/tasks/task-snapshot", record.fetch("task_url")
  end

  test "snapshot base ref falls back to origin/main without a release branch" do
    registry_path = File.join(@projects_dir, ".agents", "registry-fallback.json")

    out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write", env: { "AGENT_WORKTREE_REGISTRY" => registry_path })

    assert status.success?, err
    record = snapshot_record(registry_path)
    assert_equal "origin/main", record.fetch("base_ref")
    assert_equal "main", record.fetch("base_branch")
    assert_equal "0", record.fetch("behind_origin_main")
    assert_equal "1", record.fetch("ahead_origin_main")
    assert_match %r{/compare/main\.\.\.}, record.fetch("compare_url")
  end

  test "snapshot reckons ahead/behind and base against origin/release when present" do
    register_release_ref_ahead_of_main
    registry_path = File.join(@projects_dir, ".agents", "registry-release.json")

    out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write", env: { "AGENT_WORKTREE_REGISTRY" => registry_path })

    assert status.success?, err
    record = snapshot_record(registry_path)
    assert_equal "origin/release", record.fetch("base_ref")
    assert_equal "release", record.fetch("base_branch")
    # Feature branch carries its own commit (ahead) and is missing the
    # release-only commit (behind) — reckoned against release, not main.
    assert_equal "1", record.fetch("ahead_origin_main")
    assert_equal "1", record.fetch("behind_origin_main")
    assert_equal false, record.fetch("merged_to_origin_main")
    assert_match %r{/compare/release\.\.\.}, record.fetch("compare_url")
  end

  test "snapshot prefers origin/accepted as the base when the accepted branch exists" do
    register_release_ref_ahead_of_main
    register_accepted_ref_ahead_of_release
    registry_path = File.join(@projects_dir, ".agents", "registry-accepted.json")

    out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write", env: { "AGENT_WORKTREE_REGISTRY" => registry_path })

    assert status.success?, err
    record = snapshot_record(registry_path)
    assert_equal "origin/accepted", record.fetch("base_ref")
    assert_equal "accepted", record.fetch("base_branch")
    assert_match %r{/compare/accepted\.\.\.}, record.fetch("compare_url")
  end

  test "finish push pr blocks without a bound production task" do
    out, err, status = agent_worktree("finish", "mcritchie-studio", @task, "--push", "--pr")

    assert_not status.success?
    combined = "#{out}\n#{err}"
    assert_includes combined, "not ready for QA"
    assert_includes combined, "worktree is not bound to a production McRitchie Studio task"
  end

  test "[unit] pr body fills summary and verification from task metadata" do
    task_json = {
      "title" => "PR Handoff Autofill",
      "metadata" => {
        "devops" => {
          "acceptance" => ["Fill PR summary from task metadata", "Keep release as default PR base"],
          "checks_run" => ["[unit] bin/rails test test/commands/agent_worktree_test.rb"]
        }
      }
    }
    snippet = <<~RUBY
      ENV["AGENT_WORKTREE_TASK_JSON"] = #{JSON.generate(task_json).inspect}
      record = {
        task: "pr-handoff-autofill",
        port: "39999",
        dir: #{@worktree_dir.inspect},
        code: "000",
        env_exists: true,
        port_pid: "",
        app: { "slug" => "mcritchie-studio", "display_name" => "McRitchie Studio" },
        env: {
          "TASK_RECORD_SLUG" => "pr-handoff-autofill",
          "TASK_URL" => "https://mcritchie.studio/tasks/pr-handoff-autofill"
        }
      }
      puts pr_body(record)
    RUBY

    body = script_eval(snippet)

    assert_includes body, "- Fill PR summary from task metadata"
    assert_includes body, "- Keep release as default PR base"
    assert_includes body, "- [unit] bin/rails test test/commands/agent_worktree_test.rb"
    refute_match(/^-\\s*$/m, body, "generated PR body must not include blank bullets")
  end

  test "[unit] pr body falls back without blank bullets when task metadata is unavailable" do
    snippet = <<~RUBY
      record = {
        task: "pr-handoff-autofill",
        port: "39999",
        dir: #{@worktree_dir.inspect},
        code: "000",
        env_exists: true,
        port_pid: "",
        app: { "slug" => "mcritchie-studio", "display_name" => "McRitchie Studio" },
        env: {
          "TASK_RECORD_SLUG" => "pr-handoff-autofill",
          "TASK_URL" => "https://mcritchie.studio/tasks/pr-handoff-autofill"
        }
      }
      puts pr_body(record)
    RUBY

    body = script_eval(snippet)

    assert_includes body, "- Scope is recorded on the linked task."
    assert_includes body, "- No checks_run recorded on the linked task yet."
    refute_match(/^-\\s*$/m, body, "generated PR body must not include blank bullets")
  end

  test "[integration] finish prints a complete generated PR body" do
    agent_worktree!("bind-task", "mcritchie-studio", @task, "pr-handoff-autofill")
    task_json = {
      "title" => "PR Handoff Autofill",
      "metadata" => {
        "devops" => {
          "acceptance" => ["Fill PR summary from task metadata"],
          "checks_run" => ["[integration] bin/agent-worktree finish prints body"]
        }
      }
    }

    out, err, status = agent_worktree(
      "finish", "mcritchie-studio", @task,
      env: { "AGENT_WORKTREE_TASK_JSON" => JSON.generate(task_json) }
    )

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "ready for QA. Open a draft PR with this body:"
    assert_includes out, "- Fill PR summary from task metadata"
    assert_includes out, "- [integration] bin/agent-worktree finish prints body"
    refute_match(/^-\\s*$/m, out, "finish must not print blank PR body bullets")
  end

  test "qa-intake PR metadata includes bound task fields" do
    registry_path = write_intake_registry
    fake_bin = write_fake_gh

    out, err, status = qa_intake("--registry", registry_path, "--apps", "mcritchie-studio", "--json", env: { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" })

    assert status.success?, err
    intake = JSON.parse(out)
    pr = intake.fetch("prs").first
    assert_equal "task-intake", pr.fetch("task_record_slug")
    assert_equal "https://mcritchie.studio/tasks/task-intake", pr.fetch("task_url")
  end

  # --- doctor orphan reconciliation -----------------------------------------

  # [unit] The pure set-difference orphan_worktree_dirs loaded as a library in a
  # hermetic subprocess. Any git-listed worktree that is neither the primary
  # checkout nor a managed `.worktrees/*` dir is an orphan; a fully-managed set
  # yields none. Reproduces the bug at the lowest tier (no git, no fixtures).
  test "[unit] orphan reconciliation flags only untracked git worktrees" do
    primary = "/repo"
    managed = ["/repo/.worktrees/a", "/repo/.worktrees/b"]

    # Every git worktree is known -> no orphans.
    assert_equal [], orphan_decision(primary, managed, [primary] + managed)

    # A stray out-of-tree worktree git tracks but the registry never created.
    assert_equal ["/elsewhere/stray"],
                 orphan_decision(primary, managed, [primary, managed.first, "/elsewhere/stray"])
  end

  # [integration] A real out-of-tree git worktree (outside `.worktrees/`) must be
  # reported by `doctor` with its path, branch, and clean/merged state, and
  # doctor must NOT claim "no issues" when an orphan exists.
  test "[integration] doctor flags an out-of-tree orphan worktree" do
    orphan_dir = File.join(@projects_dir, "stray-worktree")
    git!(@hub_dir, "worktree", "add", orphan_dir, "-b", "stray/orphan")

    out, err, status = agent_worktree("doctor", "mcritchie-studio", env: command_env)

    assert status.success?, err
    assert_no_match(/no worktree lifecycle issues found/, out)
    assert_includes out, "untracked git worktree"
    assert_includes out, File.realpath(orphan_dir)
    assert_includes out, "stray/orphan"
    # The managed worktree (in `.worktrees/`) must NOT be misreported as orphan.
    assert_no_match(%r{untracked git worktree at \S*\.worktrees/}, out)
  end

  # [integration] A PRUNABLE worktree — git still LISTS it but its directory was
  # deleted on disk without `git worktree prune`. Computing branch/merge/clean
  # state used to chdir into the missing dir and raise an uncaught Errno::ENOENT,
  # crashing doctor. doctor must now exit 0 and label it distinctly as prunable.
  test "[integration] doctor survives a prunable orphan worktree" do
    orphan_dir = File.join(@projects_dir, "prunable-worktree")
    git!(@hub_dir, "worktree", "add", orphan_dir, "-b", "stray/prunable")
    realpath = File.realpath(orphan_dir)
    FileUtils.rm_rf(orphan_dir) # delete on disk; do NOT `git worktree prune`

    out, err, status = agent_worktree("doctor", "mcritchie-studio", env: command_env)

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert_no_match(/Errno::ENOENT|No such file or directory/, combined)
    assert_includes out, "prunable git worktree"
    assert_includes out, realpath
    assert_includes out, "worktree prune"
  end

  # [integration] The same prunable orphan must not crash `snapshot --write`,
  # which QA/conductor automation runs (it shares doctor_issues_by_label). It
  # must still exit 0 and write the registry.
  test "[integration] snapshot --write survives a prunable orphan worktree" do
    orphan_dir = File.join(@projects_dir, "prunable-snapshot")
    git!(@hub_dir, "worktree", "add", orphan_dir, "-b", "stray/prunable-snap")
    FileUtils.rm_rf(orphan_dir)
    registry_path = File.join(@projects_dir, ".agents", "registry-prunable.json")

    out, err, status = agent_worktree(
      "snapshot", "mcritchie-studio", "--write",
      env: { "AGENT_WORKTREE_REGISTRY" => registry_path }
    )

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert_no_match(/Errno::ENOENT|No such file or directory/, combined)
    assert File.exist?(registry_path), "snapshot must still write the registry"
  end

  # [integration] A satellite declared in satellites.yml but never cloned locally
  # (no repo dir) must not crash the no-arg doctor that automation runs:
  # `git -C <missing-repo>` degrades to no worktrees, so doctor still exits 0.
  test "[integration] doctor exits 0 when a satellite has no local clone" do
    write_satellite("ghost-app", 3300) # PROJECTS_DIR/ghost-app is never created

    out, err, status = agent_worktree("doctor", env: command_env)

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert_no_match(/Errno::ENOENT|No such file or directory/, combined)
    assert_no_match(/ghost-app/, combined)
  end

  # [unit] doctor_issues_by_label groups by label, so two orphan dirs that share
  # a basename (e.g. /a/foo and /b/foo) must produce distinct, deterministic
  # labels (basename + short path hash) rather than collapsing to one key.
  test "[unit] orphan labels disambiguate same-basename dirs by path hash" do
    a = orphan_label_for("mcritchie-studio", "/a/foo")
    b = orphan_label_for("mcritchie-studio", "/b/foo")

    assert_match %r{\Amcritchie-studio/orphan:foo-[0-9a-f]{8}\z}, a
    assert_match %r{\Amcritchie-studio/orphan:foo-[0-9a-f]{8}\z}, b
    refute_equal a, b, "same-basename orphans must not collapse to one label"
    assert_equal a, orphan_label_for("mcritchie-studio", "/a/foo"), "label must be deterministic"
  end

  # --- cleanup/reclaim hygiene output ---------------------------------------

  test "[integration] cleanup dry-run prints actionable candidate details" do
    mark_worktree_merged_to_origin_main
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", env: command_env)

    assert status.success?, err
    assert_includes out, "cleanup candidates:"
    assert_includes out, "mcritchie-studio/terminal-context"
    assert_includes out, "safe: merged on origin/main (clean, +0/-0)"
    assert_includes out, "branch: feat/terminal-context"
    assert_includes out, "stack: down"
    assert_includes out, "redis=9"
    assert_includes out, "db=mcritchie_studio_development_terminal_context"
    assert_includes out, "remove: bin/agent-worktree remove mcritchie-studio terminal-context --yes"
  end

  test "[integration] reclaim dry-run prints the same safety evidence" do
    mark_worktree_merged_to_origin_main
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", env: removal_env)

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert_includes out, "reclaim candidates:"
    assert_includes out, "safe: merged on origin/main (clean, +0/-0)"
    assert_includes out, "stack: down"
    assert_includes out, "redis=9"
    assert_includes out, "remove: bin/agent-worktree remove mcritchie-studio terminal-context --yes"
  end

  test "[integration] cleanup write records operational context in the ledger" do
    mark_worktree_merged_to_origin_main
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--write", env: command_env)

    assert status.success?, "#{out}\n#{err}"
    # Asserted on the RECORD the sweep filed, not on markdown prose — the ledger is a board
    # row now, and the operational context has to survive the move or the archive record
    # months from now is thinner than the one it replaced.
    desk = @desk_ledger.desk_for(@worktree_dir)

    assert desk, "cleanup --write must file the candidate on the desk ledger"
    assert_equal "candidate", desk["status"]
    assert_equal "cleanup", desk["source"]
    assert_includes desk["reason"], "health down, Redis DB 9"
    assert_includes desk["reason"], "database mcritchie_studio_development_terminal_context"
    assert_includes desk["safe_delete_condition"],
                    "bin/agent-worktree remove mcritchie-studio terminal-context --yes"
    # The full registry record rides along, so nothing the snapshot knew is dropped.
    assert_equal @worktree_dir, desk.dig("registry", "worktree")
  end

  test "[integration] cleanup withholds a live-claimed worktree and says WHY" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("desk-task")

    out, err, status = agent_worktree("cleanup", "mcritchie-studio",
                                      env: { "AGENT_WORKTREE_TASK_JSON" => live_claim_json })

    assert status.success?, err
    assert_includes out, "withheld mcritchie-studio/terminal-context: held by a live builder claim"
    assert_match(/builder heartbeat \d+s ago/, out, "the heartbeat age makes the hold checkable")
    # The old copy ("no clean merged or base-equivalent candidates") was a LIE here: the
    # desk IS clean and IS base-equivalent — it is simply occupied.
    assert_includes out, "no free candidates — 1 desk withheld (see the reasons above)"
    refute_includes out, "cleanup candidates:"
  end

  # THE CORRUPT FOURTH STATE. A claim whose expiry is present but unparseable is unverifiable:
  # withheld (an outage-grade "I cannot tell", not a free desk), but the reason must be HONEST.
  # Before the corrupt_expiry? branch this printed "held by a live builder claim … heartbeat  s
  # ago" — a builder that was never confirmed, plus a nil-age interpolation. This asserts the
  # honest "claim expiry unverifiable" copy propagates through report_withheld.
  test "[integration] cleanup withholds a corrupt-claim worktree as expiry-unverifiable, not a live builder" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("desk-task")

    out, err, status = agent_worktree("cleanup", "mcritchie-studio",
                                      env: { "AGENT_WORKTREE_TASK_JSON" => corrupt_claim_json })

    assert status.success?, err
    assert_includes out, "withheld mcritchie-studio/terminal-context: claim expiry unverifiable"
    refute_includes out, "held by a live builder claim",
                    "a corrupt lease is NOT a confirmed builder — the hold must not misattribute one"
    refute_match(/heartbeat\s+s ago/, out, "the garbled nil-age interpolation must be gone")
    assert_includes out, "no free candidates — 1 desk withheld (see the reasons above)"
  end

  test "[integration] reclaim dry-run withholds a live-claimed worktree" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("desk-task")

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => live_claim_json))

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "withheld mcritchie-studio/terminal-context: held by a live builder claim"
    assert_includes out, "no free candidates — 1 desk withheld (see the reasons above)"
    refute_includes out, "reclaim candidates:"
  end

  # THE DESTRUCTIVE TIER — the REFUSAL half. Its positive counterpart (the desk that IS torn
  # down) is above; both halves are needed, because this guard fails in two directions:
  # fail-open destroys a live desk, fail-closed silently wedges the sweep.
  test "[integration] reclaim --yes REFUSES to tear down a live-claimed desk" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("desk-task")
    assert Dir.exist?(@worktree_dir), "precondition: the desk is on disk"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => live_claim_json))

    assert status.success?, "#{out}\n#{err}"
    assert Dir.exist?(@worktree_dir), "the desk MUST still be on disk — the teardown is irreversible"
    assert_includes out, "withheld mcritchie-studio/terminal-context"
    refute_includes out, "reclaimed mcritchie-studio/terminal-context"
  end

  # THE UNDER-LOCK RE-VERIFY, in isolation. The candidate passes SELECTION (unclaimed on
  # the first board read), then a builder sits down and claims it mid-sweep. Teardowns run
  # serially inside the lock, so the candidate list's claim evidence is stale by the time
  # we reach the desk — the loop must re-read the claim and skip.
  test "[integration] reclaim --yes re-verifies the claim UNDER THE LOCK (builder claims mid-sweep)" do
    mark_worktree_merged_to_origin_main
    plant_task_bin_claiming_on_second_read("mid-sweep-task")
    # The desk must SURVIVE SELECTION for the under-lock re-verify to be the thing under
    # test, so stage it cold: a fresh desk is now withheld before the loop is ever reached.
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env)

    assert status.success?, "#{out}\n#{err}"
    assert Dir.exist?(@worktree_dir),
           "a builder who claimed the task AFTER selection must not have their desk destroyed"
    assert_includes out, "skipping mcritchie-studio/terminal-context: held by a live builder claim"
    refute_includes out, "reclaimed mcritchie-studio/terminal-context"
  end

  test "[integration] a LAPSED claim does not protect — the merged worktree stays a candidate" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("desk-task")
    abandon_desk! # a lapsed claim frees the CLAIM channel; the desk must be cold too

    out, err, status = agent_worktree("cleanup", "mcritchie-studio",
                                      env: { "AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json })

    assert status.success?, err
    assert_includes out, "cleanup candidates:",
                    "fail-open: a lapsed lease (a closed/crashed builder) is not live"
    refute_includes out, "withheld"
  end

  # --- the BOARD-STAGE channel, end to end (the 2026-09-20 mid-release sweep) -------------
  #
  # A real staged git worktree, merged into origin/main, long abandoned, with no open PR
  # and no claim — the shape every other channel in this file certifies as free litter. The
  # only thing separating it from a live desk is the bound task's STAGE, and before this
  # channel existed nothing asked. On 2026-09-20 a dry run offered 19 candidates, 5 of them
  # tasks at `reviewed` riding a release that was still assembling; `--yes` would have taken
  # all five and deleted the local branch behind work the sweep had not finished promoting.
  #
  # Drive BOTH cells. A guard that withheld every stage would pass the withhold checks while
  # silently wedging `cleanup --reclaim` forever, which is the other half of this gate's
  # bimodal failure.
  test "[integration] cleanup withholds a desk whose task is mid-release, and NAMES the stage" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("mid-release-task")
    abandon_desk! # every other channel deliberately clear: only the stage can withhold it

    out, err, status = agent_worktree("cleanup", "mcritchie-studio",
                                      env: { "AGENT_WORKTREE_TASK_JSON" => board_record_at("reviewed") })

    assert status.success?, err
    assert_includes out, "withheld mcritchie-studio/terminal-context: the bound task " \
                         "mid-release-task is at board stage `reviewed`",
                    "a task merged onto accepted and waiting for the release sweep is LIVE work"
    assert_includes out, "no free candidates — 1 desk withheld (see the reasons above)"
    refute_includes out, "cleanup candidates:",
                    "the desk that read `safe: merged on origin/accepted (clean)` on 2026-09-20 " \
                    "must not be offered at all"
  end

  test "[integration] reclaim --yes does NOT tear down a desk whose release is still assembling" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("mid-release-task")
    abandon_desk!
    assert Dir.exist?(@worktree_dir), "precondition: the desk is on disk"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => board_record_at("assembled")))

    assert status.success?, "#{out}\n#{err}"
    assert Dir.exist?(@worktree_dir),
           "the batch path is the one that destroys — an assembled task's desk survives it"
    assert_includes out, "board stage `assembled`"
    refute_includes out, "reclaimed mcritchie-studio/terminal-context"
  end

  # THE VALUE BEING RESTORED. The batch path was unusable during a live release because
  # nothing in its output separated a mid-flight desk from spent litter. It is usable again
  # precisely because the two now read differently: the shipped desk is TAKEN.
  test "[integration] reclaim --yes STILL tears down a desk whose task has shipped (positive control)" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("shipped-task")
    abandon_desk!
    assert Dir.exist?(@worktree_dir), "precondition: the desk is on disk"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => board_record_at("shipped")))

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "reclaimed mcritchie-studio/terminal-context",
                    "a channel that withheld every stage would be a wedge, not a fix"
    refute Dir.exist?(@worktree_dir), "a shipped task's desk is litter, and the sweep still takes it"
  end

  # LEGIBILITY, which is half the acceptance: the dry run's `rationale:` line is the approval
  # packet, and the operator must be able to SEE that the pipeline was asked. `safe: merged
  # on origin/accepted (clean)` was true of all five desks that should never have been
  # offered — the git fact was never the problem, the missing question was.
  test "[integration] the cleanup rationale prints the board stage that freed the desk" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("shipped-task")
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio",
                                      env: { "AGENT_WORKTREE_TASK_JSON" => board_record_at("archived") })

    assert status.success?, err
    assert_includes out, "cleanup candidates:"
    assert_match(/rationale:.*board stage `archived` \(terminal/, out,
                 "the stage prints beside the other channels' clearances, the way the PR and " \
                 "claim channels print theirs")
  end

  # THE CONDUCTOR'S FRONT DOOR must agree with the sweep. bin/qa-intake builds its Cleanup
  # Candidates section straight off `cleanup_candidate` and prints a `remove … --yes` per
  # row, so a registry that nominated a mid-release desk would have the operator tear down
  # by hand exactly what the sweep refuses.
  test "[integration] the registry does not nominate a desk whose task is mid-release" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("mid-release-task")
    abandon_desk!
    registry = File.join(@projects_dir, "registry.json")

    _out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write",
                                       env: { "AGENT_WORKTREE_REGISTRY" => registry,
                                              "AGENT_WORKTREE_TASK_JSON" => board_record_at("reviewed") })

    assert status.success?, err
    payload = JSON.parse(File.read(registry))
    worktree = payload.fetch("worktrees").find { |entry| entry["task"] == @task }
    refute worktree.fetch("cleanup_candidate"),
           "the conductor must not be told to remove a desk whose release is still assembling"
    assert_match(/board stage `reviewed`/, worktree.fetch("withheld_reason"), "…and it must be told WHY")
    assert_equal 1, payload.dig("summary", "withheld")
  end

  # AN UNRESOLVABLE TASK MUST NOT BE FREER THAN A KNOWN-UNSAFE ONE. A desk bound to a slug
  # the board positively answers "no such task" for has no stage to clear it. Before this
  # channel it sailed through on five clear channels — strictly freer than a desk the board
  # plainly called `reviewed`. The board ANSWERED here, so the honest remedy is the explicit
  # override, not "re-run once the board is reachable".
  test "[integration] a desk bound to a task the board cannot resolve is withheld, not freed" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("deleted-task")
    abandon_desk!
    plant_task_bin_answering_not_found

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", env: removal_env)

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "the board answered that no such task exists"
    assert_includes out, "bin/agent-worktree remove mcritchie-studio terminal-context --yes"
    refute_includes out, "cleanup candidates:"
  end

  # THE REGISTRY is the conductor's front door: bin/qa-intake builds its Cleanup Candidates
  # section straight off `cleanup_candidate` and prints a `remove … --yes` for each. It must
  # agree with the sweep, or everyone believes the desk is protected while the front door
  # still recommends tearing it down.
  test "[integration] the registry does not nominate a live-claimed desk" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("desk-task")
    registry = File.join(@projects_dir, "registry.json")

    _out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write",
                                       env: { "AGENT_WORKTREE_REGISTRY" => registry,
                                              "AGENT_WORKTREE_TASK_JSON" => live_claim_json })

    assert status.success?, err
    payload = JSON.parse(File.read(registry))
    worktree = payload.fetch("worktrees").find { |entry| entry["task"] == @task }
    refute worktree.fetch("cleanup_candidate"), "the conductor must not be told to remove a held desk"
    assert_match(/live builder claim/, worktree.fetch("withheld_reason"), "…and it must be told WHY")
    assert_equal 0, payload.dig("summary", "cleanup_candidates"), "the summary agrees with the field"
    assert_equal 1, payload.dig("summary", "withheld")
  end

  # The registry's `withheld_reason` is the field bin/qa-intake reads to bucket occupied desks
  # (withheld_reason_for). For a corrupt claim it must carry the honest "claim expiry
  # unverifiable" reason, NOT a misattributed live-builder line — so the conductor's front door
  # tells the operator to inspect the task, not that a phantom builder is sitting there.
  test "[integration] the registry names a corrupt claim as expiry-unverifiable, not a live builder" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("desk-task")
    registry = File.join(@projects_dir, "registry.json")

    _out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write",
                                       env: { "AGENT_WORKTREE_REGISTRY" => registry,
                                              "AGENT_WORKTREE_TASK_JSON" => corrupt_claim_json })

    assert status.success?, err
    payload = JSON.parse(File.read(registry))
    worktree = payload.fetch("worktrees").find { |entry| entry["task"] == @task }
    refute worktree.fetch("cleanup_candidate"), "an unverifiable desk must not be nominated for teardown"
    reason = worktree.fetch("withheld_reason")
    assert_match(/expiry unverifiable/, reason, "the field the conductor reads must state the honest reason")
    refute_match(/live builder/, reason, "…and must not misattribute a builder we never confirmed")
    assert_equal 1, payload.dig("summary", "withheld")
  end

  # THE UNBOUND DESK is the original incident's own desk: TASK_RECORD_SLUG is written by
  # bind-task, never by `new`, so a builder inside the new -> bind-task -> move building
  # window has no task and therefore no claim we can read. The CLAIM channel is forced to
  # fail open on it — you cannot look up what you cannot identify — and it says so, because
  # this is the likeliest desk to lose. (The fixture worktree is unbound, which is why the
  # guard's board read never fires for it.)
  #
  # Which is precisely why the DESK channel must not fail open too. This pair pins both
  # halves: the claim announcement still happens, AND a fresh unbound desk survives anyway.
  test "[integration] an UNBOUND desk announces no claim could be checked, and survives while fresh" do
    mark_worktree_merged_to_origin_main

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", env: {})

    assert status.success?, err
    assert_match(/has no bound task, so no desk claims one/, err,
                 "the desk we actually lost must not fail open in silence")
    refute_includes out, "cleanup candidates:",
                    "a desk with no claim to check is the one the sweep ate — the desk channel " \
                    "has to catch what the claim channel structurally cannot"
    assert_match(/withheld .*the desk is only/, out, "and the hold names the reason: it is new")
  end

  # THE OTHER HALF, and the reason the pair exists. A half-allocated desk (worktree created,
  # stack and bind-task failed — the Redis band ceiling produced several on the incident day)
  # is unbound litter, and once it has gone cold it is exactly what reclaim is for. Protecting
  # every unidentifiable desk forever would trade a data-loss bug for a leak.
  test "[integration] a COLD unbound desk is still nominated — the fail-open is bounded, not removed" do
    mark_worktree_merged_to_origin_main
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", env: {})

    assert status.success?, err
    assert_includes out, "cleanup candidates:",
                    "an unbound desk nobody has touched in days is litter — the sweep must collect it"
  end

  # THE POSITIVE CONTROL — the one cell the asymmetry matrix never covered.
  #
  # This guard's failure mode is BIMODAL: fail-open destroys a live desk (the original
  # incident), and fail-CLOSED silently wedges the entire reclaim sweep. Every other
  # `--reclaim --yes` test in this file asserts a REFUSAL, so if the guard withheld EVERY
  # desk the whole suite would stay green while reclaim was quietly dead — and teardown is
  # now gated by four clauses, any one of which could regress that way. This asserts the
  # sweep still DESTROYS: a readable desk whose claim has lapsed is torn down for real.
  test "[integration] reclaim --yes STILL tears down a readable, unclaimed desk (positive control)" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("desk-task")
    abandon_desk!
    assert Dir.exist?(@worktree_dir), "precondition: the desk is on disk"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json))

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "reclaimed mcritchie-studio/terminal-context",
                    "a guard that withholds everything is a wedge, not a fix"
    refute Dir.exist?(@worktree_dir), "the desk is actually torn down — the sweep still works"
    refute_includes out, "withheld"
  end

  # THE SAME CONTROL, THROUGH THE REAL FETCH PATH.
  #
  # The control above rides AGENT_WORKTREE_TASK_JSON, which short-circuits
  # task_record_for_pr BEFORE fetch_task_record ever runs — it certifies the sweep's
  # free × strict cell while leaving the real board read uncovered. The mid-sweep test
  # DOES drive the real path, but every record it feeds through it is either {}-devops
  # (selection) or LIVE-claimed (under the lock), and it ends in a REFUSAL. So the one
  # record shape a finished desk actually carries — readable, with a LAPSED claim — never
  # rides the real seam to a completed teardown, and a wedge in fetch_task_record's
  # success path that misclassifies exactly that record as unreadable passed the whole
  # suite green while wedging every real sweep shut (verified: the wedge went undetected
  # by all 95 runs until this test, which it turns red). This is that teardown, end to
  # end through a planted bin/task — no JSON override — with the read counter proving the
  # real fetch actually ran.
  test "[integration] reclaim --yes tears down a lapsed-claim desk through the REAL fetch path (positive control)" do
    mark_worktree_merged_to_origin_main
    counter = plant_task_bin_with_lapsed_claim("fetch-path-task")
    abandon_desk!
    assert Dir.exist?(@worktree_dir), "precondition: the desk is on disk"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env)

    assert status.success?, "#{out}\n#{err}"
    assert_operator File.read(counter).to_i, :>=, 1,
                    "the planted bin/task was never consulted — the sweep bypassed the real " \
                    "fetch path, so this control proved nothing"
    assert_includes out, "reclaimed mcritchie-studio/terminal-context",
                    "a readable, lapsed-claim desk read through the REAL board seam must still " \
                    "be torn down — withholding it wedges the sweep for every finished desk"
    refute Dir.exist?(@worktree_dir), "the desk is torn down for real, through the real fetch path"
    refute_includes out, "withheld"
    refute_includes out, "skipping"
  end

  # ── THE ORIGIN-UNREACHABLE WITHHOLD, end to end through the CLI ────────────────────────
  #
  # The in-process control in origin_unreachable_reclaim_test.rb is
  # `assert_nil origin_hold(record_for("/projects/healthy"))`, which only proves an
  # EMPTY-HASH lookup returns nil — it cannot fail unless the guard defaults to
  # withholding. So NEITHER half of this behaviour had an end-to-end proof: the
  # reclaiming half lived in the suite this change turned red, and the withholding half
  # was never exercised through the CLI at all.
  #
  # These are that proof, and they are exact negatives of the positive control above —
  # same desk, same lapsed claim, same teardown path, ONE variable flipped.
  test "[integration] reclaim --yes WITHHOLDS a desk whose origin could not be reached" do
    mark_worktree_merged_to_origin_main
    plant_task_bin_with_lapsed_claim("origin-error-task")
    abandon_desk!
    assert Dir.exist?(@worktree_dir), "precondition: the desk is on disk"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_ORIGIN_FETCH" => "error"))

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "origin could not be reached",
                    "the sweep must SAY it could not consult the origin — an operator reading " \
                    "the head of the output is how this surfaces at all"
    assert_includes out, "withheld mcritchie-studio/terminal-context"
    assert_includes out, "no free candidates"
    assert Dir.exist?(@worktree_dir),
           "a desk whose origin could not be consulted must survive --yes: its merge evidence " \
           "is stale, and stale evidence is not permission to delete"
  end

  # The RETIRED-repo wording, which is the case the guard was actually built for. A
  # deleted remote's tracking refs are frozen in a merged-looking state, so they read
  # as ELIGIBLE forever — the one case where "stale refs are conservative anyway" is
  # false.
  test "[integration] reclaim --yes WITHHOLDS a desk whose origin no longer exists" do
    mark_worktree_merged_to_origin_main
    plant_task_bin_with_lapsed_claim("origin-gone-task")
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_ORIGIN_FETCH" => "gone"))

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "origin no longer exists on the remote (retired repo)"
    assert_includes out, "no free candidates"
    assert Dir.exist?(@worktree_dir), "a retired repo's desk is never provably reclaimable"
  end

  # THE INVARIANT, which is the half that actually reached the operator. ORIGIN_UNREACHABLE
  # used to be populated ONLY by the reclaim sweep, so `cleanup --write` evaluated
  # origin_hold against an EMPTY map, got nil, and FILED the desk into
  # docs/agents/maintenance/delete-later.md — where bin/qa-intake then printed
  # `remove ... --yes` for it. Over-nominate-then-refuse fails safe, but it misleads the
  # conductor, and it broke the promise reclaim_verdict's own comment makes.
  test "[integration] cleanup --write does NOT nominate a desk whose origin is unreachable" do
    mark_worktree_merged_to_origin_main
    plant_task_bin_with_lapsed_claim("origin-ledger-task")
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--write",
                                      env: removal_env("AGENT_WORKTREE_ORIGIN_FETCH" => "error"))

    assert status.success?, "#{out}\n#{err}"
    refute_includes out, "cleanup candidates:",
                    "the ledger-filing path must route through the SAME hold as the sweep; " \
                    "nominating here is what put a withheld desk in front of the conductor"
    assert_includes out, "withheld mcritchie-studio/terminal-context"
  end

  # ── THE FRESH DESK, end to end through the real filesystem ────────────────────────────
  #
  # 2026-08-13: a builder created and bound an industries desk, and a `cleanup --reclaim`
  # sweep removed it while he was working in it. Nothing malfunctioned. The desk was CLEAN
  # (nobody had committed yet) and carried NOTHING ahead of its base, so cleanup_ready?
  # passed — a fresh worktree and a fast-forward-merged one are byte-identical to git, so
  # the desk that looked safest to destroy was the one that was somebody's next hour of work.
  # The blast radius is another session's UNCOMMITTED work, which no gate, review or CI can
  # ever catch, because it never becomes a commit.
  #
  # Every check below hands the guard a LAPSED claim on purpose. The claim channel therefore
  # says "free" for all of them — that channel already had its coverage above, and pinning it
  # live here would prove nothing about the hole. What is under test is the DESK.
  #
  # These run against the real staged git worktree with real mtimes and a real `.git`
  # marker, because the whole failure was a decision made about a DIRECTORY.

  test "[integration] reclaim dry-run does NOT nominate a freshly created, bound, clean desk" do
    mark_worktree_merged_to_origin_main # git-identical to the merged desk it was mistaken for
    bind_task_slug("fresh-desk-task")

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json))

    assert status.success?, "#{out}\n#{err}"
    refute_includes out, "reclaim candidates:",
                    "a desk created minutes ago must never reach the candidate list — the dry run " \
                    "is what the operator reads before typing --yes"
    assert_includes out, "withheld mcritchie-studio/terminal-context"
    assert_match(/the desk is only .* old/, out, "the hold states the fact it turned on")
  end

  # THE DESTRUCTIVE TIER of the same case — the one that actually cost work.
  test "[integration] reclaim --yes SPARES a freshly created, bound, clean desk" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("fresh-desk-task")
    assert Dir.exist?(@worktree_dir), "precondition: the desk is on disk"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json))

    assert status.success?, "#{out}\n#{err}"
    assert Dir.exist?(@worktree_dir),
           "the desk MUST still be on disk: this is the exact teardown that destroyed a live " \
           "builder's uncommitted work, and it is irreversible"
    assert_includes out, "withheld mcritchie-studio/terminal-context"
    refute_includes out, "reclaimed mcritchie-studio/terminal-context"
  end

  # AGE IS A FLOOR, NOT THE ANSWER. A desk hours old that somebody is editing right now is
  # live, and an age threshold alone would hand it straight back to the sweep. Here the desk
  # is aged past the floor, then ONE file is written — the agent-editing-code case that the
  # board can never see, because an edit is not a commit and not a board write.
  test "[integration] reclaim --yes SPARES an aged desk that is being edited right now" do
    bind_task_slug("aged-but-busy-task")
    abandon_desk! # the desk is old…

    # …but the builder is still at it. The work is COMMITTED and LANDED, so the desk reads
    # clean and 0-ahead and reclaim's whole git test passes — while `feature.txt` still
    # carries the mtime of the edit that produced it (committing does not touch the working
    # file). This is an ordinary steady state, not a contrivance: the PR merged onto
    # `accepted` and its builder is still sitting at the desk, between changes.
    File.write(File.join(@worktree_dir, "feature.txt"), "still working here\n")
    git!(@worktree_dir, "commit", "-am", "Ongoing work")
    mark_worktree_merged_to_origin_main
    refute git_dirty?(@worktree_dir), "premise: the desk is CLEAN — dirtiness would protect it for free"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json))

    assert status.success?, "#{out}\n#{err}"
    assert Dir.exist?(@worktree_dir),
           "a desk being written to is in use, however old it is and whatever the board says"
    assert_match(/the desk was written to within the last/, out)
    refute_includes out, "reclaimed mcritchie-studio/terminal-context"
  end

  # THE MID-CERT DESK, which is why "just add an age threshold" was not the fix. A cert
  # writes NOTHING into its desk for up to the measured 94-minute p99, so an hour-old desk
  # running one is indistinguishable from a walked-away desk by age AND by mtimes. The gate
  # channel is the only thing that separates them — the same channel the claim lease keeps,
  # read holder-scoped off the board record.
  test "[integration] reclaim --yes SPARES an aged, quiet desk whose holder has a gate in flight" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("mid-cert-task")
    abandon_desk!
    mid_cert = JSON.generate("holder_gate_in_flight" => true, "stage" => TERMINAL_STAGE,
                             "metadata" => { "devops" => JSON.parse(lapsed_claim_json)
                                                             .dig("metadata", "devops") })

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => mid_cert))

    assert status.success?, "#{out}\n#{err}"
    assert Dir.exist?(@worktree_dir),
           "a holder mid-cert writes nothing into the desk for up to 94 minutes — silence there " \
           "is the cert running, not a builder who left"
    assert_match(/a gate the holder may have opened is still running/, out)
    refute_includes out, "reclaimed mcritchie-studio/terminal-context"
  end

  # ── THE CONTROL ───────────────────────────────────────────────────────────────────────
  #
  # The proof the fix is a fix and not a disabling. Every check above asserts a REFUSAL, so
  # a guard that simply withheld everything would leave them all green while reclaim was
  # silently dead — and a dead sweep is how the Redis band reaches its ceiling and starts
  # producing half-allocated desks. A desk that is merged, unclaimed, days old and untouched
  # is genuinely abandoned, and it must still be torn down for real.
  test "[integration] reclaim --yes STILL tears down a genuinely merged and abandoned desk (control)" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("abandoned-task")
    abandon_desk!
    assert Dir.exist?(@worktree_dir), "precondition: the desk is on disk"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json))

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "reclaimed mcritchie-studio/terminal-context",
                    "a guard that withholds every desk is a wedge, not a fix"
    refute Dir.exist?(@worktree_dir), "the abandoned desk is actually torn down"
    refute_includes out, "withheld"
  end

  # THE ESCAPE HATCH, and the proof it is still open. The desk channel withholds a fresh desk
  # from every AUTOMATIC path — that is the fix — but `remove <app> <task> --yes` is the
  # explicit operator override, and it must still work. Otherwise a fix for a data-loss bug
  # becomes a Redis-band leak with no way out, and the band was already at its ceiling on the
  # day of the incident. It warns and proceeds.
  test "[integration] remove --yes still tears down a FRESH desk, warning without blocking" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("fresh-desk-task")

    out, err, status = agent_worktree("remove", "mcritchie-studio", @task, "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json))

    assert status.success?, "#{out}\n#{err}"
    refute Dir.exist?(@worktree_dir),
           "the explicit operator path must still remove a desk on demand — a guard with no " \
           "override wedges the band it was supposed to protect"
    assert_match(/the desk is only .* old/, err, "…while saying plainly what it found")
    refute_match(/a builder appears to be on this desk/, err,
                 "and never asserting a builder nobody confirmed — the hold here is the desk's " \
                 "age, not a person")
  end

  # THE REGISTRY AGREES, on both sides. bin/qa-intake builds its Cleanup Candidates section
  # straight off `cleanup_candidate` and prints a `remove … --yes` per entry, so a front door
  # that still nominated a fresh desk would re-open the incident one indirection out — the
  # operator would be handed the removal command for a desk the sweep itself refuses.
  test "[integration] the registry does not nominate a freshly created desk either" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("fresh-desk-task")
    registry = File.join(@projects_dir, "registry.json")

    _out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write",
                                       env: { "AGENT_WORKTREE_REGISTRY" => registry,
                                              "AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json })

    assert status.success?, err
    worktree = JSON.parse(File.read(registry)).fetch("worktrees").find { |entry| entry["task"] == @task }
    refute worktree.fetch("cleanup_candidate"),
           "the conductor's front door must not hand the operator a removal command for a new desk"
    assert_match(/the desk is only/, worktree.fetch("withheld_reason"), "…and it must say why")
  end

  # THE DESTROY-PATH ASYMMETRY — the blocker from round 3.
  #
  # A BOUND task whose board record cannot be read (board 500, timeout, auth failure) is the
  # one case where we KNOW the desk could be claimed and simply failed to find out — unlike
  # unbound (cannot identify it) or lapsed (checked; the builder is gone). The board 500s
  # under Postgres connection pressure during heavy parallel devops, which is exactly when
  # many worktrees exist and the reclaim sweep gets run: outage and mass-reclaim are
  # CORRELATED, so failing open here re-opens the original incident precisely when everyone
  # believes it is covered. Withholding during an outage is a deferral; failing open is an
  # irreversible teardown.
  test "[integration] reclaim --yes WITHHOLDS a bound desk whose board record cannot be read" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("board-is-down")
    assert Dir.exist?(@worktree_dir), "precondition: the desk is on disk"

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("AGENT_WORKTREE_TASK_JSON" => "null"))

    assert status.success?, "#{out}\n#{err}"
    assert Dir.exist?(@worktree_dir),
           "an unverifiable desk must survive the destroy path — an outage is a reason to defer, " \
           "not a licence to tear down a desk we could not check"
    assert_includes out, "withheld mcritchie-studio/terminal-context"
    assert_match(/board record could not be read/, out)
    refute_includes out, "reclaimed mcritchie-studio/terminal-context"
  end

  # THE CLEANUP LANE withholds it too — there is no "advisory" lane. `cleanup` prints a
  # `remove … --yes` per candidate and `--write` files it in the delete-later ledger, so it
  # NOMINATES for destruction just as surely as the sweep does.
  test "[integration] cleanup WITHHOLDS a bound desk whose board record cannot be read" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("board-is-down")

    out, err, status = agent_worktree("cleanup", "mcritchie-studio",
                                      env: { "AGENT_WORKTREE_TASK_JSON" => "null" })

    assert status.success?, err
    assert_match(/bound to task board-is-down, but its board record could not be read/, err,
                 "a guard that gives up on checking must be loud about it")
    assert_includes out, "withheld mcritchie-studio/terminal-context"
    refute_includes out, "cleanup candidates:", "an unverifiable desk is never nominated"

    # BLOCKER 2: the summary must not name a reason the per-desk line contradicts. It used to
    # hardcode "withheld for a live builder claim" — telling the operator a builder was sitting
    # at a desk whose record simply could not be read.
    assert_includes out, "withheld (see the reasons above)"
    refute_includes out, "withheld for a live builder claim"
  end

  # BLOCKER 1: the REGISTRY is a destroy path by proxy — bin/qa-intake builds its Cleanup
  # Candidates list off `cleanup_candidate` and prints a `remove … --yes` for each. If it
  # failed open during an outage, the sweep would withhold a live builder's desk while the
  # conductor's front door recommended destroying it. It must agree with the sweep.
  test "[integration] the registry does not nominate an UNVERIFIABLE desk during a board outage" do
    mark_worktree_merged_to_origin_main
    bind_task_slug("board-is-down")
    registry = File.join(@projects_dir, "registry.json")

    _out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write",
                                       env: { "AGENT_WORKTREE_REGISTRY" => registry,
                                              "AGENT_WORKTREE_TASK_JSON" => "null" })

    assert status.success?, err
    payload = JSON.parse(File.read(registry))
    worktree = payload.fetch("worktrees").find { |entry| entry["task"] == @task }
    refute worktree.fetch("cleanup_candidate"),
           "during an outage qa-intake must NOT be told to remove a desk the sweep would withhold"
    assert_match(/could not be read/, worktree.fetch("withheld_reason"),
                 "and the reason must say it is unverifiable, not that a builder is on it")
    assert_equal 0, payload.dig("summary", "cleanup_candidates")
    assert_match(/could not be read/, err, "the registry lane announces too — it does not give up in silence")
  end

  # --- the 2026-08-14 sweep: three load-bearing desks nominated as "safe" -----
  #
  # A `cleanup --reclaim` listed 29 desks as "safe: merged on origin/accepted (clean)".
  # Three were in use: one another live session was reviewing, and BOTH repos' `_ship`
  # workspaces, which the release sweep running at that moment was building gem locks
  # inside. Every one of them was genuinely clean and genuinely landed on the base — which
  # is the lesson: git-cleanliness is not the safety property.
  #
  # These drive the WHOLE script over a staged fixture, through the real gh and
  # release-claim seams, and each pairs its refusal with the control that frees the same
  # desk — a guard that withheld everything would pass the refusals alone and wedge the
  # sweep in silence.

  test "[integration] reclaim dry-run WITHHOLDS a desk whose branch has an OPEN unmerged PR" do
    mark_worktree_merged_to_origin_main
    abandon_desk!
    fake_bin = write_fake_gh_pr_state(open_pr: 41)

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim",
                                      env: removal_env("PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}"))

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert_includes combined, "OPEN, unmerged pull request (#41)",
                    "an open PR is live work; the sweep must refuse the desk and name the PR"
    assert_no_match(/reclaim candidates:/, out,
                    "a desk with an open PR must not even be PROPOSED — the dry run is what the " \
                    "operator approves from")
  end

  test "[integration] reclaim --yes SPARES a desk whose branch has an OPEN unmerged PR" do
    mark_worktree_merged_to_origin_main
    abandon_desk!
    fake_bin = write_fake_gh_pr_state(open_pr: 41)

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env("PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}"))

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert Dir.exist?(@worktree_dir),
           "the destroy path must spare it too — a dry run that refuses while --yes proceeds is " \
           "the worst of both\n#{combined}"
  end

  # THE CONTROL, and the reason this pair exists: the SAME abandoned, merged desk with
  # nothing open on it is still ordinary litter. Without this, a guard that always withheld
  # would pass the two checks above while quietly ending all reclaim.
  test "[integration] reclaim still nominates the same desk once no PR is open" do
    mark_worktree_merged_to_origin_main
    abandon_desk!
    fake_bin = write_fake_gh_pr_state(open_pr: nil)

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim",
                                      env: removal_env("PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}"))

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert_includes out, "reclaim candidates:"
    assert_includes out, "mcritchie-studio/terminal-context"
  end

  # `_ship` IS NOT "the tree the deploy works in". `bin/release prepare` — the ASSEMBLER —
  # merges release branches forward and runs `bundle lock` for every consumer inside it. The
  # guard used to ask only about the `deployer` role, so during a live prepare it answered
  # "no ship is live" and nominated both workspaces. Here the release-claim CLI answers LIVE
  # for assembler and NOT-LIVE (exit 3) for deployer: a deployer-only guard sees :none.
  test "[integration] reclaim never proposes _ship while a live PREPARE (assembler) holds the release" do
    stage_ship_workspace!
    write_fake_release_claim_cli(live_roles: %w[assembler])

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", env: removal_env)

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert_includes combined, "a release is live",
                    "a live prepare pins _ship exactly as a ship does"
    assert_no_match(/^  - mcritchie-studio\/_ship$/, out,
                    "_ship must not be proposed while a release conductor holds a claim")
  end

  test "[integration] reclaim --yes SPARES _ship while a live PREPARE holds the release" do
    stage_ship_workspace!
    write_fake_release_claim_cli(live_roles: %w[assembler])

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes",
                                      env: removal_env)

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert Dir.exist?(File.join(@hub_dir, ".worktrees", "_ship")),
           "tearing down _ship mid-prepare breaks the release sweep that is writing in it\n#{combined}"
  end

  # THE CONTROL for the release channel: with every role free, the workspaces are ordinary
  # litter and bin/release recreates them on demand.
  test "[integration] reclaim proposes _ship when no release conductor holds a claim" do
    stage_ship_workspace!
    write_fake_release_claim_cli(live_roles: [])

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", env: removal_env)

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert_includes out, "mcritchie-studio/_ship",
                    "no live release ⇒ _ship is a normal candidate, or the guard has wedged the sweep"
  end

  # "Every archive records its rationale." The dry run states what each channel asked and
  # answered, and the ledger row — the archive record a reader lands on months later —
  # carries the same sentence beside the git facts.
  test "[integration] every nominated candidate explains itself, in the dry run and in the ledger" do
    mark_worktree_merged_to_origin_main
    abandon_desk!
    fake_bin = write_fake_gh_pr_state(open_pr: nil)
    env = command_env("PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}")

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", env: env)
    assert status.success?, "#{out}\n#{err}"
    assert_match(/rationale: .*no open PR for feat\/terminal-context \(GitHub asked\)/, out,
                 "the dry run must say which questions were asked — `safe: merged (clean)` is a " \
                 "git fact, and it was true of all three desks the 08-14 sweep should have kept")
    assert_match(/rationale: .*desk idle/, out)

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--write", env: env)
    assert status.success?, "#{out}\n#{err}"
    desk = @desk_ledger.desk_for(@worktree_dir)

    assert desk, "cleanup --write must file the candidate on the desk ledger"
    assert_includes desk["reason"], "Cleared:",
                    "an archive row without a rationale is what made the 08-13 sweep ambiguous"
    assert_includes desk["reason"], "no open PR for feat/terminal-context"
  end

  # The conductor's front door prints a `remove … --yes` per candidate, so it carries the
  # same rationale the sweep computed — one call, one decision, one explanation.
  test "[integration] the registry carries the rationale for every desk it nominates" do
    mark_worktree_merged_to_origin_main
    abandon_desk!
    fake_bin = write_fake_gh_pr_state(open_pr: nil)
    registry = File.join(@projects_dir, "rationale-registry.json")

    out, err, status = agent_worktree("snapshot", "mcritchie-studio", "--write",
                                      env: { "AGENT_WORKTREE_REGISTRY" => registry,
                                             "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" })

    assert status.success?, "#{out}\n#{err}"
    worktree = JSON.parse(File.read(registry)).fetch("worktrees").find { |entry| entry["task"] == @task }
    assert worktree.fetch("cleanup_candidate"), "premise: this desk is nominated"
    assert_includes worktree.fetch("cleanup_rationale"), "no open PR for feat/terminal-context",
                    "qa-intake recommends the teardown, so it must carry the evidence too"
  end

  # --- remove --force (merge-verified) --------------------------------------

  # [unit] The pure decision force_clears_content_blocker? loaded as a library in
  # a hermetic subprocess (the dispatch guard keeps `load` side-effect-free).
  test "[unit] force clears the content blocker only when merge-verified and clean" do
    assert_equal "true",  force_decision(dirty: false, force: true,  merged: true)
    assert_equal "false", force_decision(dirty: false, force: true,  merged: false)
  end

  test "[unit] force never clears the content blocker for a dirty worktree" do
    assert_equal "false", force_decision(dirty: true, force: true, merged: true)
  end

  test "[unit] without force the content-blocker decision is unchanged" do
    assert_equal "false", force_decision(dirty: false, force: false, merged: true)
    assert_equal "false", force_decision(dirty: true,  force: false, merged: false)
  end

  # [integration] run_remove end-to-end over the temp worktree. The feature
  # branch carries a commit not on origin/main (the squash-merge shape), so the
  # content guard always fires; --force + a merge-verified PR is the only override.
  test "[integration] force with a merge-verified PR removes a content-blocked worktree" do
    out, err, status = agent_worktree(
      "remove", "mcritchie-studio", @task, "--force", "--yes",
      env: removal_env("AGENT_WORKTREE_MERGED_PR" => "159")
    )

    combined = "#{out}\n#{err}"
    assert status.success?, combined
    assert_includes combined, "PR #159 merged"
    assert_includes combined, "overriding content-not-on-main guard (--force)"
    assert_not Dir.exist?(@worktree_dir), "worktree should have been removed"
  end

  test "[integration] force refuses when no merged PR can be verified" do
    fake_bin = write_fake_gh_unmerged

    out, err, status = agent_worktree(
      "remove", "mcritchie-studio", @task, "--force", "--yes",
      env: removal_env("PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}")
    )

    combined = "#{out}\n#{err}"
    assert_not status.success?, combined
    assert_includes combined, "branch content is not represented on"
    assert_includes combined, "--force requires a merged PR; none found for feat/terminal-context"
    assert Dir.exist?(@worktree_dir), "worktree must be left intact when force is unverified"
  end

  test "[integration] force never overrides a dirty worktree even with a merged PR" do
    File.write(File.join(@worktree_dir, "scratch.txt"), "uncommitted\n")

    out, err, status = agent_worktree(
      "remove", "mcritchie-studio", @task, "--force", "--yes",
      env: removal_env("AGENT_WORKTREE_MERGED_PR" => "159")
    )

    combined = "#{out}\n#{err}"
    assert_not status.success?, combined
    assert_includes combined, "dirty worktree"
    assert_no_match(/overriding content-not-on/, combined)
    assert Dir.exist?(@worktree_dir), "dirty worktree must never be removed"
  end

  test "[integration] without force a content-blocked worktree still refuses unchanged" do
    out, err, status = agent_worktree(
      "remove", "mcritchie-studio", @task, "--yes",
      env: removal_env
    )

    combined = "#{out}\n#{err}"
    assert_not status.success?, combined
    assert_includes combined, "branch content is not represented on"
    assert_no_match(/--force/, combined)
    assert Dir.exist?(@worktree_dir), "no-force behavior must be unchanged"
  end

  # --- worktree isolated test DB provisioning -------------------------------

  # [unit] test_database_url rewrites a worktree's DEV DATABASE_URL into the name
  # of an isolated TEST DB: the `_development[_slug]` env marker -> `_test[_slug]`,
  # a marker-less name still gets a `_test` DB, and no DATABASE_URL -> nil. This
  # is the name both .env.test.local and db:test:prepare key off.
  test "[unit] test_database_url derives an isolated test DB from the dev DATABASE_URL" do
    base = "postgresql://localhost"
    assert_equal "#{base}/app_test_my_slug",
                 script_eval(%(print test_database_url("DATABASE_URL" => "#{base}/app_development_my_slug").to_s)).strip
    assert_equal "#{base}/app_test",
                 script_eval(%(print test_database_url("DATABASE_URL" => "#{base}/app_development").to_s)).strip
    assert_equal "#{base}/plain_test",
                 script_eval(%(print test_database_url("DATABASE_URL" => "#{base}/plain").to_s)).strip
    assert_equal "", script_eval(%(print test_database_url({}).to_s)).strip
  end

  # [unit] write_test_env_local drops a gitignored .env.test.local that pins
  # TEST_DATABASE_URL at the isolated test DB. dotenv auto-loads it for the test
  # env so a plain `bin/rails test` resolves there even with DATABASE_URL at the
  # seeded dev DB. No DATABASE_URL -> nothing to derive -> no file.
  test "[unit] write_test_env_local pins TEST_DATABASE_URL to the isolated test DB" do
    dir = Dir.mktmpdir("test-env-local")
    empty = Dir.mktmpdir("test-env-local-empty")
    begin
      script_eval(%(write_test_env_local(#{dir.inspect}, "DATABASE_URL" => "postgresql://localhost/app_development_demo")))
      content = File.read(File.join(dir, ".env.test.local"))
      assert_includes content, "TEST_DATABASE_URL=postgresql://localhost/app_test_demo"
      assert_includes content, "do not commit"

      script_eval(%(write_test_env_local(#{empty.inspect}, {})))
      assert_not File.exist?(File.join(empty, ".env.test.local")),
                 "no DATABASE_URL must write no test-env pointer"
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(empty)
    end
  end

  # [unit] config/database.yml: the test env exposes TEST_DATABASE_URL via an
  # explicit `url:` (an explicit url wins over DATABASE_URL) and falls back to the
  # shared `mcritchie_studio_test` when it is unset — so CI / normal local are
  # unchanged while a worktree can pin its own isolated test DB.
  test "[unit] database.yml test env reads TEST_DATABASE_URL with a shared-DB fallback" do
    yml = Rails.root.join("config/database.yml").read
    original = ENV["TEST_DATABASE_URL"]
    begin
      ENV["TEST_DATABASE_URL"] = "postgresql://localhost/iso_test"
      set = YAML.safe_load(ERB.new(yml).result, aliases: true).fetch("test")
      assert_equal "postgresql://localhost/iso_test", set["url"],
                   "test.url must surface TEST_DATABASE_URL so it can win over DATABASE_URL"

      ENV.delete("TEST_DATABASE_URL")
      unset = YAML.safe_load(ERB.new(yml).result, aliases: true).fetch("test")
      assert unset["url"].to_s.strip.empty?, "test.url must be blank without TEST_DATABASE_URL"
      assert_equal "mcritchie_studio_test", unset.fetch("database")
    ensure
      original.nil? ? ENV.delete("TEST_DATABASE_URL") : ENV["TEST_DATABASE_URL"] = original
    end
  end

  # [integration] The real app boots in the test env and resolves its DB through
  # the actual config/database.yml + dotenv stack. With DATABASE_URL at a dev DB
  # (as a worktree exports) AND TEST_DATABASE_URL at the isolated test DB, the
  # test env MUST resolve to the test DB — the regression that made a plain
  # `bin/rails test` load `fixtures :all` into the seeded dev DB and FK-fail.
  test "[integration] test env resolves to TEST_DATABASE_URL over a dev DATABASE_URL" do
    out, err, status = Open3.capture3(
      SessionEnv.neutralized(
        "RAILS_ENV" => "test",
        "DATABASE_URL" => "postgresql://localhost/mcritchie_studio_development_db_resolution_probe",
        "TEST_DATABASE_URL" => "postgresql://localhost/mcritchie_studio_test_db_resolution_probe",
        "PATH" => ENV.fetch("PATH", "")
      ),
      RbConfig.ruby, Rails.root.join("bin/rails").to_s, "runner",
      'print ActiveRecord::Base.configurations.configs_for(env_name: "test").map(&:database).join(",")',
      chdir: Rails.root.to_s
    )

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "mcritchie_studio_test_db_resolution_probe"
    assert_no_match(/development/, out)
  end

  # --- worktree DB-name overflow (PG 63-byte identifier limit) ---------------

  # [unit] Reproduces the bug at the lowest tier: a long worktree slug used to
  # mint a 64-char DEV database name (`<app>_development_<slug>`), one byte over
  # Postgres' 63-byte identifier limit, so the stored datname was truncated while
  # Rails looked it up by the full literal string. worktree_db_name must now keep
  # the dev name <= 63 AND keep the derived test name (the `_development_` ->
  # `_test_` rewrite) <= 63 sharing an IDENTICAL <slug> base, so db:test:prepare
  # resolves the same DB.
  test "[unit] worktree_db_name bounds a long slug; dev and test share a <=63 base" do
    long = "mascot-marker-no-downgrade-fallback-extra-long-slug" # > 40 chars
    out = script_eval(<<~RUBY).strip
      require "json"
      dev  = worktree_db_name("mcritchie-studio", "#{long}")
      test = test_database_url("DATABASE_URL" => "postgresql://localhost/\#{dev}").split("/").last
      print JSON.generate("dev" => dev, "test" => test)
    RUBY
    parsed = JSON.parse(out)
    dev = parsed.fetch("dev")
    test = parsed.fetch("test")

    assert_operator dev.length, :<=, 63, "dev DB name must fit Postgres' 63-byte identifier limit"
    assert_operator test.length, :<=, 63, "derived test DB name must fit too"
    assert dev.start_with?("mcritchie_studio_development_"), dev
    assert test.start_with?("mcritchie_studio_test_"), test

    # The shared <slug> base is what makes db:test:prepare resolve the same DB the
    # dev URL points at — dev and test must differ ONLY in the env marker.
    dev_slug = dev.sub("mcritchie_studio_development_", "")
    test_slug = test.sub("mcritchie_studio_test_", "")
    assert_equal dev_slug, test_slug, "dev and test DB names must share an identical slug base"
    assert_match(/_[0-9a-f]{8}\z/, dev_slug, "an overflowing slug is truncated + suffixed with a short digest")
  end

  # [unit] A slug that already fits passes through byte-for-byte: short-slug
  # worktrees keep the exact name they use today (no churn / no surprise reprovision).
  test "[unit] worktree_db_name leaves a fitting slug byte-for-byte unchanged" do
    out = script_eval(%(print worktree_db_name("mcritchie-studio", "terminal-context"))).strip
    assert_equal "mcritchie_studio_development_terminal_context", out
  end

  # [unit] The truncation+hash mapping is deterministic (same slug -> same name
  # across runs) and unique (two long slugs differing past the truncation point
  # must not collide), with every result still <= 63.
  test "[unit] worktree_db_name is deterministic and collision-resistant for long slugs" do
    base = "alpha-marker-no-downgrade-fallback-very-long-worktree-slug"
    a1 = script_eval(%(print worktree_db_name("mcritchie-studio", "#{base}"))).strip
    a2 = script_eval(%(print worktree_db_name("mcritchie-studio", "#{base}"))).strip
    b = script_eval(%(print worktree_db_name("mcritchie-studio", "#{base}X"))).strip

    assert_equal a1, a2, "same slug must yield the same DB name (deterministic digest)"
    refute_equal a1, b, "long slugs differing past the truncation point must not collide"
    assert_operator a1.length, :<=, 63
    assert_operator b.length, :<=, 63
  end

  # [integration] The real regression, end-to-end: db:test:prepare must succeed
  # for a LONG-slug worktree and the test DB it provisions must be findable by its
  # full literal name. At 64 bytes Postgres truncated the stored datname to 63
  # while the literal pg_database lookup used the un-truncated name -> miss. With
  # the fix the bounded name is <= 63, so the stored name and the lookup match.
  #
  # CI portability: the dev/test URLs and the psql/dropdb cleanup are derived from
  # a template connection URL (swapping ONLY the database-name segment) so the
  # real credentials ride through. CI's Postgres needs a password — a hardcoded
  # `postgresql://localhost/...` + a PATH-only psql env die at connect with
  # `fe_sendauth: no password supplied` BEFORE the regression runs. Prefer
  # DATABASE_URL (CI sets it with creds); fall back to TEST_DATABASE_URL (a local
  # worktree sets that one, trust-auth localhost) so the test runs in both places.
  test "[integration] db:test:prepare provisions a findable long-slug test DB" do
    template = pg_template_url
    skip "no DATABASE_URL/TEST_DATABASE_URL to derive Postgres credentials from" if template.blank?
    template_uri = URI.parse(template)

    # UNIQUE PER RUN, and it must be. This was a hardcoded literal, so every
    # concurrent session on the box derived the SAME database name on the SAME
    # Postgres cluster — and the `ensure` below drops it. Session A's dropdb could
    # land between session B's db:test:prepare and B's pg_database probe, reddening
    # B on a correct implementation. Same family as the shared-state fixes in this
    # commit: a test whose verdict depended on what another agent was doing.
    #
    # The suffix rides safely through truncation because bounded_db_slug digests the
    # WHOLE slug (SHA256, bin/agent-worktree) before clipping — so uniqueness lands
    # in the digest, not in the part that gets cut. The probe's real subject is
    # unchanged: this slug is still far over the 63-byte identifier limit.
    long_slug = "regression-very-long-worktree-slug-db-name-overflow-probe-#{SecureRandom.hex(4)}"
    dev_name = script_eval(%(print worktree_db_name("mcritchie-studio", "#{long_slug}"))).strip
    test_name = script_eval(
      %(print test_database_url("DATABASE_URL" => "postgresql://localhost/#{dev_name}").split("/").last)
    ).strip

    assert_operator dev_name.length, :<=, 63
    assert_operator test_name.length, :<=, 63

    pg_env = pg_conn_env(template_uri)
    drop_test_db = ->(name) { system(pg_env, "dropdb", "--if-exists", name, out: File::NULL, err: File::NULL) }
    # Lease the UNIQUE per-run DB before provisioning it: the `ensure` drops it on a
    # clean exit, but a SIGKILL runs no `ensure`, and this lease is what lets the next
    # run's CertDatabaseReaper drop the database this one stranded. See the reaper.
    CertDatabaseReaper.register(test_name)
    begin
      out, err, status = Open3.capture3(
        SessionEnv.neutralized(
          "RAILS_ENV" => "test",
          "DATABASE_URL" => db_url_with_name(template_uri, dev_name),
          "TEST_DATABASE_URL" => db_url_with_name(template_uri, test_name),
          "PATH" => ENV.fetch("PATH", "")
        ),
        RbConfig.ruby, Rails.root.join("bin/rails").to_s, "db:test:prepare",
        chdir: Rails.root.to_s
      )
      assert status.success?, "db:test:prepare failed for a long-slug worktree:\n#{out}\n#{err}"

      found, ferr, fstatus = Open3.capture3(
        pg_env, "psql", "-Atqc",
        "SELECT 1 FROM pg_database WHERE datname = '#{test_name}'", "postgres"
      )
      assert fstatus.success?, ferr
      assert_equal "1", found.strip,
        "the provisioned test DB must be findable by its full literal name (no truncation drift)"
    ensure
      CertDatabaseReaper.release(test_name, drop: drop_test_db)
    end
  end

  # --- restore-primary: return a drifted primary checkout to a clean main ----
  # The real bin run against a temp git repo (PROJECTS_DIR/@hub_dir is the
  # primary). GIT_SSH_COMMAND=/usr/bin/false makes the allow_fail `git fetch
  # origin` (ssh-form origin) fail INSTANTLY offline, so restore proceeds against
  # the local refs/remotes/origin/main setup_repo registers — no network, no hang.

  test "restore-primary returns a clean checkout drifted onto a review branch to main" do
    # Primary drifted onto a leftover review branch; origin/main advanced past it.
    advanced = advance_origin_main_ahead
    git!(@hub_dir, "branch", "pr-181", "main") # a review branch at old main (all pushed)
    git!(@hub_dir, "checkout", "pr-181")

    out, err, status = agent_worktree("restore-primary", "mcritchie-studio", env: offline_git)

    assert status.success?, "#{out}\n#{err}"
    assert_equal "main", head_branch(@hub_dir), "primary restored to main"
    assert_equal advanced, rev(@hub_dir, "main"), "main fast-forwarded to origin/main"
    assert_match(/restored primary pr-181 .* main/, err)
  end

  test "restore-primary fast-forwards a clean main that is behind origin" do
    advanced = advance_origin_main_ahead # primary stays on main, now behind origin
    refute_equal advanced, rev(@hub_dir, "main"), "premise: main is behind origin/main"

    out, err, status = agent_worktree("restore-primary", "mcritchie-studio", env: offline_git)

    assert status.success?, "#{out}\n#{err}"
    assert_equal "main", head_branch(@hub_dir)
    assert_equal advanced, rev(@hub_dir, "main"), "behind-main fast-forwarded up to origin/main"
    assert_match(/already on main; fast-forwarded/, err)
  end

  test "restore-primary REFUSES a dirty tree and preserves the uncommitted change" do
    File.write(File.join(@hub_dir, "README.md"), "# Locally edited, uncommitted\n")

    out, err, status = agent_worktree("restore-primary", "mcritchie-studio", env: offline_git)

    refute status.success?, "must exit non-zero on a dirty primary\n#{out}"
    assert_match(/refusing to restore mcritchie-studio/, err)
    assert_match(/uncommitted/, err)
    assert_equal "# Locally edited, uncommitted\n", File.read(File.join(@hub_dir, "README.md")),
      "the uncommitted change must NOT be discarded"
  end

  test "restore-primary REFUSES a branch carrying unpushed commits" do
    git!(@hub_dir, "checkout", "-b", "wip-local") # a local commit on no remote
    File.write(File.join(@hub_dir, "wip.txt"), "wip\n")
    git!(@hub_dir, "add", "wip.txt")
    git!(@hub_dir, "commit", "-m", "Local-only WIP")
    head_before = rev(@hub_dir, "HEAD")

    out, err, status = agent_worktree("restore-primary", "mcritchie-studio", env: offline_git)

    refute status.success?, "must exit non-zero on unpushed work\n#{out}"
    assert_match(/refusing to restore mcritchie-studio/, err)
    assert_match(/unpushed/, err)
    assert_equal "wip-local", head_branch(@hub_dir), "must NOT switch away from unpushed work"
    assert_equal head_before, rev(@hub_dir, "HEAD"), "the local commit must be preserved"
  end

  test "restore-primary --dry-run reports the plan and mutates nothing" do
    git!(@hub_dir, "branch", "pr-9", "main")
    git!(@hub_dir, "checkout", "pr-9")

    out, err, status = agent_worktree("restore-primary", "mcritchie-studio", "--dry-run", env: offline_git)

    assert status.success?, "#{out}\n#{err}"
    assert_match(/would restore primary/, err)
    assert_equal "pr-9", head_branch(@hub_dir), "dry-run leaves the checkout untouched"
  end

  # WRITTEN AS `def test_…`, NOT as `test "…"`, and that makes their VISIBILITY
  # load-bearing: Minitest collects only PUBLIC test methods, so a `private` ANYWHERE
  # above them in this class body would leave them DEFINED and never RUN — and a
  # `-n /registry/` filter still reports green, because it matches OTHER tests whose
  # names contain "registry". That is a test that cannot fail, reported as proof.
  #
  # The class carries no `private` at all now that the harness lives in
  # test/support/agent_worktree_fixture.rb. If one ever comes back, it belongs BELOW
  # these two — or write them with the `test "…"` macro, which defines through
  # `define_method` and is not touched by the surrounding default visibility.

  # ── [integration] this script writes THREE stores in the operator's real .agents ──
  #
  # The registry, the DB-allocation flock, and the elastic Redis band all resolve by
  # the same PROJECTS_DIR-else-real-root fallback that leaked the cost store (PR #525)
  # and the narration markers (PR #549). Nobody had them on a list — the containment
  # test (test/lib/state_store_containment_test.rb) found them by reading the tree.
  # The pins were already CORRECT here — they live in the fixture's command_env now —
  # they were just remembered rather than enforced, and a pin you have to remember is
  # the bug. Now an unpinned spawn aborts instead of overwriting the live registry
  # every conductor session reads.
  #
  # Spawned fully unpinned, so this drives the real fallback — and the guard aborts
  # BEFORE any IO, so it never writes the store even when it goes red.
  #
  # ── WHY THIS RUNS A STAGED COPY OF THE SCRIPT ────────────────────────────────
  #
  # The first version of this test asserted the mtime of the OPERATOR'S LIVE
  # registry (<projects>/.agents/worktree-registry.json) was unchanged across the
  # spawn. The claim was right; the instrument was machine-global. Any concurrent
  # agent session doing something entirely legitimate — `bin/agent-worktree new`,
  # a conductor snapshot — rewrote that file inside our window and reddened a cert
  # that had found nothing wrong. It was a member of the same family as the
  # wall-clock assertion in test/lib/cert_orphan_guard_test.rb: a test asserting
  # the state of the BOX, and so a test any other agent could fail for us.
  #
  # The fix keeps the test fully unpinned — that is the whole point of it — and
  # moves the FALLBACK instead. ProjectsRoot.default_projects_dir (bin/lib/) derives
  # the root from the RUNNING SCRIPT'S OWN LOCATION, so a copy staged under the
  # tmpdir hub resolves <tmpdir>/.agents through exactly the same code path, and the
  # store this test protects is one it owns and tears down. Nothing else on the
  # machine can touch it, and this test can no longer touch anything else.
  #
  # `SENTINEL` makes the proof stronger than the mtime version could be: we could
  # never pre-seed the operator's real registry, so it could only ask "did the
  # timestamp move". Owning the file lets us assert exact CONTENT — a write of any
  # size, including one that lands within a filesystem timestamp granule, fails.
  def test_integration_an_unpinned_registry_write_aborts_instead_of_reaching_the_real_store
    script = stage_script
    registry = File.join(@projects_dir, ".agents", "worktree-registry.json")
    FileUtils.mkdir_p(File.dirname(registry))
    File.write(registry, SENTINEL)

    env = SessionEnv.neutralized("PATH" => ENV.fetch("PATH", "")) # every pin unset
    _out, err, status = Open3.capture3(env, RbConfig.ruby, script, "snapshot", "--write", chdir: @hub_dir)

    refute_predicate status, :success?, "an unpinned registry write must ABORT, not fall back to the real store"
    assert_match(/sandbox/i, err, "the abort must say WHY")
    assert_match(/AGENT_WORKTREE_REGISTRY|PROJECTS_DIR/, err, "and must name a var to pin")

    # ANTI-VACUITY, and the assertion that keeps the redirection honest: the refusal
    # must name OUR tmpdir root. Without this the test would still pass if the staged
    # copy resolved the operator's real root instead — the sentinel would sit
    # untouched while the live store took the write, which is the exact inversion of
    # what this test claims to prove.
    assert_match(/#{Regexp.escape(@projects_dir)}/, err,
                 "the fallback must resolve into the test's own root, not the operator's")
    assert_equal SENTINEL, File.read(registry), "the fallback registry must be untouched, byte for byte"
  end

  # The happy path the guard must not break — pinned, the snapshot still lands.
  def test_integration_a_pinned_registry_write_still_lands
    registry_path = File.join(@projects_dir, ".agents", "pinned-registry.json")
    out, err, status = agent_worktree("snapshot", "--write", env: { "AGENT_WORKTREE_REGISTRY" => registry_path })

    assert_predicate status, :success?, "#{out}\n#{err}"
    assert_path_exists registry_path, "a pinned snapshot must still write the registry"
  end

  # ==== THE HARNESS SELF-TESTS ======================================================
  #
  # A pin nobody exercised is advice. Each test below drives the DANGEROUS shape —
  # the one that reaches for production — and asserts a POSITIVE RECEIPT that the
  # seam intercepted it. The absence of a symptom proves nothing here: every leak
  # this file used to have was a silent SUCCESS, not a failure, so "the suite is
  # green" was exactly the signal that hid it.
  #
  # If a future change routes one of these calls past its seam, the matching test
  # fails and NAMES the break, instead of the suite quietly resuming production
  # traffic.

  SINK_HOST = "127.0.0.1"

  # A fake secret, so the child gets FAR ENOUGH to open a socket. bin/task resolves
  # AGENT_API_SECRET from ENV → the repo .env → 1Password and dies if all three
  # miss; on CI all three DO miss, so without this the child would exit before the
  # sink ever saw a connection and the receipt would refuse for the wrong reason.
  # The value can only ever be offered to a localhost sink, because TASK_API_BASE
  # is pinned in the same env hash.
  PIN_PROOF_SECRET = "pin-proof-not-a-real-secret"

  # Run the command with the board pinned at a sink this test owns; answer the HTTP
  # request lines the sink received.
  def sink_requests(*args, env: {})
    server = TCPServer.new(SINK_HOST, 0)
    base = "http://#{SINK_HOST}:#{server.addr[1]}"
    received = []
    accepter = Thread.new do
      while (client = server.accept)
        received << client.gets.to_s
        client.write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end

    agent_worktree(*args, env: { "TASK_API_BASE" => base, "ATOMIC_CAPTURE_URL" => base,
                                "AGENT_API_SECRET" => PIN_PROOF_SECRET }.merge(env))

    deadline = Time.now + 20
    sleep 0.05 while received.empty? && Time.now < deadline
    received
  ensure
    accepter&.kill
    server&.close
  end

  # THE BOARD PIN, proven against the REAL bin/task — the binary that defaults to
  # https://mcritchie.studio. The seam is deliberately pointed BACK at the real CLI
  # here: pinning the binary is containment, but it is not proof that the BASE URL
  # holds, and the base URL is the last line for every path that still reaches the
  # genuine article (bin/agent-worktree's own fetch_task_record, a script added
  # later, a test that overrides the binary seam).
  test "[integration] the board pin intercepts the REAL bin/task this script shells" do
    received = sink_requests("bind-task", "mcritchie-studio", @task, "pin-proof-task",
                             env: { "AGENT_WORKTREE_TASK_BIN" => Rails.root.join("bin/task").to_s })

    refute_empty received,
                 "the board pin did NOT intercept: bin/agent-worktree shelled the real bin/task " \
                 "and it made no request to the pinned TASK_API_BASE. Either it reached a " \
                 "DIFFERENT host — production is bin/task's default — or it died before opening " \
                 "a socket (a missing AGENT_API_SECRET does that; see PIN_PROOF_SECRET). This " \
                 "suite's containment lives on this pin."
    assert_match(%r{^(GET|POST|PATCH|PUT) }, received.first,
                 "expected an HTTP request line at the sink, got #{received.first.inspect}")
  end

  # THE TASK-BINARY SEAM, proven on the path the script actually takes. Mutation
  # check for this one: revert task_cli_path in bin/agent-worktree to
  # File.join(__dir__, "task") and this goes red, because the recorded call
  # disappears — the read went to the real CLI instead.
  test "[integration] the task-binary seam is on the path bind-task actually takes" do
    OutboundSeams.reset!

    agent_worktree!("bind-task", "mcritchie-studio", @task, "seam-proof-task")

    reads = OutboundSeams.calls_to("task-cli")
    refute_empty reads,
                 "bind-task made NO call through AGENT_WORKTREE_TASK_BIN. The seam is not on the " \
                 "path: the mascot reads went to whatever `#{Rails.root.join("bin/task")}` is, " \
                 "which authenticates against the production board by default."
    assert(reads.any? { |line| line.include?("field seam-proof-task mascot") },
           "expected the mascot field read through the seam, got #{reads.inspect}")
  end

  # THE SSH PIN. setup_repo gives the fixture a REAL origin
  # (git@github.com:McRitchie-Studio/mcritchie-studio.git) so github_repo_slug can
  # resolve, and run_finish fetches it before the blocker check this asserts on.
  # That fetch used to leave the machine, because this call site passed no env at
  # all while its siblings pinned GIT_SSH_COMMAND by hand.
  test "[integration] the ssh pin intercepts the fixture's real github remote" do
    OutboundSeams.reset!

    out, err, status = agent_worktree("finish", "mcritchie-studio", @task, "--push", "--pr")

    assert_not status.success?, "#{out}\n#{err}"
    assert_includes "#{out}\n#{err}", "worktree is not bound to a production McRitchie Studio task"
    attempts = OutboundSeams.calls_to("ssh")
    refute_empty attempts,
                 "`finish --push --pr` fetched origin and NOTHING intercepted it, so the fetch " \
                 "used the machine's real ssh against #{"git@github.com:McRitchie-Studio/mcritchie-studio.git".inspect}. " \
                 "GIT_SSH_COMMAND must be pinned by command_env, for every spawn, not per test."
    assert(attempts.any? { |line| line.include?("github.com") },
           "expected the intercepted ssh to name the fixture's remote host, got #{attempts.inspect}")
  end

  # THE gh SEAL. An unsealed gh here is worse than a stray read: the operator's
  # keyring token is invalid, so gh refuses AUTH-shaped, which arms GhAuthRetry and
  # mints a real App installation token through 1Password. The stub answers with an
  # empty body precisely so that classifier cannot fire.
  test "[integration] the sealed gh answers the merged-PR lookup, not the operator's gh" do
    OutboundSeams.reset!

    out, err, status = agent_worktree("remove", "mcritchie-studio", @task, "--force", "--yes",
                                      env: removal_env)

    combined = "#{out}\n#{err}"
    assert_not status.success?, combined
    assert_includes combined, "--force needs gh; not available",
                    "the sealed gh refuses, so the merged-PR lookup must report UNAVAILABLE — " \
                    "a different verdict here means something answered for it\n#{combined}"
    refute_empty OutboundSeams.calls_to("gh"),
                 "the merged-PR lookup ran `gh pr list` against the REAL github: nothing was " \
                 "recorded by the sealed stub, so PATH resolved the operator's gh."
    assert_empty OutboundSeams.calls_to("gh-token"),
                 "a gh refusal armed the token mint. The seal answers with an EMPTY body for " \
                 "exactly this reason — an auth-shaped refusal reaches 1Password and mints a " \
                 "real production credential."
  end

  # Content pre-seeded into the staged root's registry, so an unpinned write that
  # reached it is caught by CONTENT rather than by a timestamp.
  SENTINEL = "{\"sentinel\":\"must not be overwritten\"}\n"

end
