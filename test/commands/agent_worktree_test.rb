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

class AgentWorktreeCommandTest < ActiveSupport::TestCase
  def setup
    # realpath so derived paths match git's canonical worktree-list output on
    # macOS (/var and /tmp are symlinks into /private), which registered_worktree?
    # compares by exact string.
    @projects_dir = File.realpath(Dir.mktmpdir("agent-worktree-command"))
    @hub_dir = File.join(@projects_dir, "mcritchie-studio")
    @task = "terminal-context"
    @worktree_dir = File.join(@hub_dir, ".worktrees", @task)
    @script = Rails.root.join("bin/agent-worktree").to_s
    setup_repo
  end

  def teardown
    FileUtils.rm_rf(@projects_dir) if @projects_dir
  end

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
    ledger = File.read(File.join(@hub_dir, "docs", "agents", "maintenance", "delete-later.md"))
    assert_includes ledger, "health down, Redis DB 9"
    assert_includes ledger, "database mcritchie_studio_development_terminal_context"
    assert_includes ledger, "bin/agent-worktree remove mcritchie-studio terminal-context --yes"
  end

  # --- reclaim guard: a live-claimed builder desk is never destroyed ----------
  # A fresh worktree and a fast-forward-merged one are git-identical (clean, HEAD == base,
  # 0-ahead), so ONLY the task's live build-claim (ClaimLease) separates a desk a builder
  # just sat down at from finished work. The claim is read through the same board seam as
  # the PR autofill; AGENT_WORKTREE_TASK_JSON stands in for the board's task record.
  # The lease TTL is 120s (ClaimLease::DEFAULT_TTL_SECONDS).
  CLAIM_TTL = 120

  def claim_json(expires_at, session:)
    JSON.generate("metadata" => { "devops" => {
                    "claimed_session" => session, "claim_expires_at" => expires_at.utc.iso8601
                  } })
  end

  # A lease renewed ~10s ago — a builder whose status line is alive.
  def live_claim_json
    claim_json(Time.now + (CLAIM_TTL - 10), session: "sess-live")
  end

  # A lease that lapsed an hour ago — a closed/crashed builder.
  def lapsed_claim_json
    claim_json(Time.now - 3600, session: "sess-dead")
  end

  # A lease whose expiry is PRESENT but unparseable — the corrupt state. live? cannot rule it
  # lapsed (we could not check), so the desk is WITHHELD, but the honest hold reason is "claim
  # expiry unverifiable", never "held by a live builder" (we never confirmed one). claim_json
  # can't build this — it iso8601-formats a Time — so it is spelled out here.
  def corrupt_claim_json
    JSON.generate("metadata" => { "devops" => {
                    "claimed_session" => "sess-corrupt", "claim_expires_at" => "not-a-timestamp"
                  } })
  end

  # Bind a task slug into the fixture worktree's stack env so the guard's board read gets
  # past its "no bound task" early return and actually resolves a record.
  def bind_task_slug(slug)
    env_path = File.join(@worktree_dir, ".env.agent-stack")
    File.write(env_path, "#{File.read(env_path)}\nTASK_RECORD_SLUG=#{slug}\n")
  end

  # A fake `bin/task` that reports the task UNCLAIMED on the first `show` and LIVE-claimed
  # on every later one — the builder-sits-down-mid-sweep race. Planted in the HUB (the
  # documented fallback), never inside the worktree, which would dirty it and disqualify
  # it from cleanup for the wrong reason.
  def plant_task_bin_claiming_on_second_read(slug)
    bind_task_slug(slug)
    counter = File.join(@projects_dir, "task-show-count")
    bin = File.join(@hub_dir, "bin", "task")
    FileUtils.mkdir_p(File.dirname(bin))
    expires = (Time.now + (CLAIM_TTL - 10)).utc.iso8601
    File.write(bin, <<~SH)
      #!/bin/sh
      n=$(cat #{counter.shellescape} 2>/dev/null || echo 0)
      echo $((n + 1)) > #{counter.shellescape}
      if [ "$n" -eq 0 ]; then
        echo '{"metadata":{"devops":{}}}'
      else
        echo '{"metadata":{"devops":{"claimed_session":"sess-midsweep","claim_expires_at":"#{expires}"}}}'
      fi
    SH
    FileUtils.chmod(0o755, bin)
  end

  # A fake `bin/task` that reports the task readable with a LAPSED claim on EVERY read —
  # the record every finished desk actually carries (claimed while building; the lease
  # lapses when the builder closes). Same hub plant as the mid-sweep helper above, plus a
  # read counter so the test can PROVE the real fetch path ran: a positive control that can
  # pass without exercising its path is no control at all. Returns the counter path.
  def plant_task_bin_with_lapsed_claim(slug)
    bind_task_slug(slug)
    counter = File.join(@projects_dir, "task-show-count")
    bin = File.join(@hub_dir, "bin", "task")
    FileUtils.mkdir_p(File.dirname(bin))
    expires = (Time.now - 3600).utc.iso8601
    File.write(bin, <<~SH)
      #!/bin/sh
      n=$(cat #{counter.shellescape} 2>/dev/null || echo 0)
      echo $((n + 1)) > #{counter.shellescape}
      echo '{"metadata":{"devops":{"claimed_session":"sess-dead","claim_expires_at":"#{expires}"}}}'
    SH
    FileUtils.chmod(0o755, bin)
    counter
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
    assert_match(/has no bound task, so no build claim can be checked/, err,
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
    mid_cert = JSON.generate("holder_gate_in_flight" => true,
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

  private

  # Template Postgres connection URL to derive host/port/user/password from.
  # CI sets DATABASE_URL (with credentials); a local worktree sets TEST_DATABASE_URL
  # (trust-auth localhost). Blank means no database is reachable -> the caller skips.
  def pg_template_url
    url = ENV["DATABASE_URL"].to_s
    url = ENV["TEST_DATABASE_URL"].to_s if url.strip.empty?
    url.strip
  end

  # Rebuild a connection URL from a template URI, swapping ONLY the database-name
  # path segment. Scheme/userinfo/host/port/query are preserved, so the derived
  # dev/test URLs carry the template's real credentials.
  def db_url_with_name(template_uri, db_name)
    uri = template_uri.dup
    uri.path = "/#{db_name}"
    uri.to_s
  end

  # Subprocess env for bare psql/dropdb, derived from the template URI so the
  # cleanup connects with the same credentials (a PATH-only env -> fe_sendauth on CI).
  def pg_conn_env(template_uri)
    env = SessionEnv.neutralized("PATH" => ENV.fetch("PATH", ""))
    env["PGHOST"] = template_uri.host if template_uri.host.present?
    env["PGPORT"] = template_uri.port.to_s if template_uri.port
    env["PGUSER"] = template_uri.user if template_uri.user.present?
    env["PGPASSWORD"] = template_uri.password if template_uri.password.present?
    env
  end

  # Load bin/agent-worktree as a library in a hermetic subprocess (the
  # $PROGRAM_NAME == __FILE__ dispatch guard keeps `load` side-effect-free) and
  # evaluate a snippet against its pure helpers. Returns stdout. Mirrors
  # force_decision/orphan_decision below.
  def script_eval(snippet)
    out, err, status = Open3.capture3(
      SessionEnv.neutralized("PROJECTS_DIR" => @projects_dir, "PATH" => ENV.fetch("PATH", "")),
      RbConfig.ruby, "-e", "load #{@script.inspect}\n#{snippet}"
    )
    assert status.success?, "#{out}\n#{err}"
    out
  end

  # Drive the pure decision method directly by loading the script as a library in
  # an isolated subprocess (mirrors the file's CLI execution path; the
  # $PROGRAM_NAME == __FILE__ guard means `load` defines methods without running
  # the dispatch). Returns the printed "true"/"false".
  def force_decision(dirty:, force:, merged:)
    snippet = <<~RUBY
      load #{@script.inspect}
      puts force_clears_content_blocker?({ dirty: #{dirty} }, force: #{force}, merged: #{merged})
    RUBY
    out, err, status = Open3.capture3(
      SessionEnv.neutralized("PROJECTS_DIR" => @projects_dir, "PATH" => ENV.fetch("PATH", "")),
      RbConfig.ruby, "-e", snippet
    )
    assert status.success?, "#{out}\n#{err}"
    out.strip
  end

  # Drive the pure orphan_worktree_dirs reconciliation directly via `load` in an
  # isolated subprocess (same hermetic pattern as force_decision). Returns the
  # orphan path array.
  def orphan_decision(primary, managed, git_dirs)
    snippet = <<~RUBY
      require "json"
      load #{@script.inspect}
      puts JSON.generate(orphan_worktree_dirs(#{primary.inspect}, #{managed.inspect}, #{git_dirs.inspect}))
    RUBY
    out, err, status = Open3.capture3(
      SessionEnv.neutralized("PROJECTS_DIR" => @projects_dir, "PATH" => ENV.fetch("PATH", "")),
      RbConfig.ruby, "-e", snippet
    )
    assert status.success?, "#{out}\n#{err}"
    JSON.parse(out.strip)
  end

  # Drive the pure orphan_label labeller via `load` in an isolated subprocess
  # (same hermetic pattern as orphan_decision). Returns the computed label.
  def orphan_label_for(slug, dir)
    snippet = <<~RUBY
      load #{@script.inspect}
      puts orphan_label({ "slug" => #{slug.inspect} }, #{dir.inspect})
    RUBY
    out, err, status = Open3.capture3(
      SessionEnv.neutralized("PROJECTS_DIR" => @projects_dir, "PATH" => ENV.fetch("PATH", "")),
      RbConfig.ruby, "-e", snippet
    )
    assert status.success?, "#{out}\n#{err}"
    out.strip
  end

  # Declare a satellite app in the hub's config/satellites.yml without cloning
  # its repo (PROJECTS_DIR/<slug> never exists), exercising the missing-clone path.
  def write_satellite(slug, port)
    path = File.join(@hub_dir, "config", "satellites.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~YAML)
      satellites:
        - slug: #{slug}
          display_name: #{slug}
          port: #{port}
          status: active
    YAML
  end

  # Env for run_remove tests: scratch registry, plus any per-test overrides
  # (merged-PR injection, fake-gh PATH).
  #
  # GIT_SSH_COMMAND used to be pinned here, at "/usr/bin/false", and that pin is
  # the reason this file's ssh containment was believed to be handled: it made the
  # allow_fail `git fetch origin` fail instantly with no network — for the REMOVAL
  # tests, and only for them. The `finish --push --pr` test three hundred lines up
  # passed no env at all, against a fixture whose origin is a real
  # git@github.com:McRitchie-Studio/... URL. So the pin now lives in the floor
  # (OutboundSeams, via command_env), where it covers every spawn in the file, and
  # what it points at is a RECORDING refusal rather than /usr/bin/false — same
  # instant failure, but it leaves a receipt, so a test can prove the interception
  # happened instead of inferring it from the absence of a hang.
  def removal_env(extra = {})
    { "AGENT_WORKTREE_REGISTRY" => File.join(@projects_dir, ".agents", "remove-registry.json") }.merge(extra)
  end

  def write_fake_gh_unmerged
    dir = File.join(@projects_dir, "fake-bin-unmerged")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      if ARGV[0, 2] == ["pr", "list"]
        puts "[]"
      else
        warn "unexpected gh args: \#{ARGV.join(" ")}"
        exit 1
      end
    RUBY
    File.chmod(0o755, path)
    dir
  end

  def mark_worktree_merged_to_origin_main
    git!(@hub_dir, "update-ref", "refs/remotes/origin/main", rev(@worktree_dir, "HEAD"))
  end

  # Age the fixture desk into a genuinely ABANDONED one — born long ago, untouched since.
  #
  # WHY EVERY TEARDOWN CONTROL NOW NEEDS THIS. `mark_worktree_merged_to_origin_main` used
  # to be the whole story: clean + landed on base was the reclaim test. That is exactly the
  # defect — a brand-new worktree satisfies BOTH vacuously (clean because nobody has written
  # yet, landed because it carries nothing), so a merged desk and a live one an agent sat
  # down at ten minutes ago are byte-identical to git. A control that asserts a TEARDOWN
  # must therefore stage the second half of the story too: nobody has been here in a long
  # time. Staging it in a named helper keeps the premise visible in each test rather than
  # buried in setup, because it IS the premise.
  #
  # Backdates the worktree `.git` marker (the desk's birthday, read by
  # DeskActivity.age_seconds) and every file under it (the mtimes read by
  # DeskActivity.touched_since?). Call it LAST — anything written afterwards, a
  # `bind_task_slug` rewrite included, makes the desk read as live again.
  def abandon_desk!(age_seconds: 3 * 24 * 60 * 60)
    at = Time.now - age_seconds
    paths = Dir.glob(File.join(@worktree_dir, "**", "*"), File::FNM_DOTMATCH)
                .reject { |path| %w[. ..].include?(File.basename(path)) }
    (paths + [@worktree_dir]).each do |path|
      File.utime(at, at, path)
    rescue SystemCallError
      nil # a path that raced away is not the point of the fixture
    end
    assert_operator Time.now - File.mtime(File.join(@worktree_dir, ".git")), :>,
                    ClaimLease::DESK_IDLE_SECONDS,
                    "premise: the desk must read as older than the idle window"
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

  # Force the ssh-form origin fetch to fail instantly offline (restore is then
  # against the local origin/main ref). command_env's floor already pins this for
  # every spawn in the file; naming it at these call sites keeps the premise
  # legible where the assertion depends on the fetch NOT succeeding.
  def offline_git
    { "GIT_SSH_COMMAND" => OutboundSeams.stub("ssh") }
  end

  def head_branch(dir)
    out, = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", "--abbrev-ref", "HEAD", chdir: dir)
    out.strip
  end

  def rev(dir, ref)
    out, = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", ref, chdir: dir)
    out.strip
  end

  # Mirrors the script's own dirtiness test. Used to PIN a premise rather than to assert a
  # result: a check about a desk that is clean-yet-occupied proves nothing if the fixture
  # quietly went dirty, because dirtiness disqualifies a desk from reclaim on its own.
  def git_dirty?(dir)
    out, = Open3.capture3(SessionEnv.neutralized, "git", "status", "--porcelain", chdir: dir)
    !out.strip.empty?
  end

  # Advance refs/remotes/origin/main ONE commit past the local main (origin moved
  # ahead) without disturbing the feature worktree. Returns the new origin/main
  # SHA. Mirrors register_release_ref_ahead_of_main.
  def advance_origin_main_ahead
    build = File.join(@projects_dir, "origin-build")
    git!(@hub_dir, "worktree", "add", "-b", "origin-build", build, "main")
    git!(build, "config", "user.email", "agent-test@example.com")
    git!(build, "config", "user.name", "Agent Test")
    File.write(File.join(build, "origin.txt"), "origin\n")
    git!(build, "add", "origin.txt")
    git!(build, "commit", "-m", "Origin-only commit")
    sha, _err, status = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", "HEAD", chdir: build)
    assert status.success?, "could not resolve origin-build HEAD"
    git!(@hub_dir, "update-ref", "refs/remotes/origin/main", sha.strip)
    git!(@hub_dir, "worktree", "remove", build, "--force")
    git!(@hub_dir, "branch", "-D", "origin-build")
    sha.strip
  end

  def setup_repo
    FileUtils.mkdir_p(@hub_dir)
    # delete-later.md lives here; teardown_worktree appends a removal row to it.
    FileUtils.mkdir_p(File.join(@hub_dir, "docs", "agents", "maintenance"))
    git!(@hub_dir, "init")
    git!(@hub_dir, "config", "user.email", "agent-test@example.com")
    git!(@hub_dir, "config", "user.name", "Agent Test")
    git!(@hub_dir, "checkout", "-b", "main")
    File.write(File.join(@hub_dir, "README.md"), "# Test repo\n")
    git!(@hub_dir, "add", "README.md")
    git!(@hub_dir, "commit", "-m", "Initial commit")
    # Mirror the real repos: agent stack/context files are gitignored so a
    # provisioned worktree reads as clean (otherwise every worktree is "dirty"
    # and un-removable). Committed on main before the worktree branch is cut.
    # Mirror the real repo's .gitignore: /.worktrees/ is ignored so the parent
    # checkout reads CLEAN with a feature worktree provisioned under it (otherwise
    # `git status` in @hub_dir flags .worktrees/ as untracked → "dirty").
    File.write(File.join(@hub_dir, ".gitignore"), ".env.agent-stack\n.agent-context.json\n/.worktrees/\n")
    git!(@hub_dir, "add", ".gitignore")
    git!(@hub_dir, "commit", "-m", "Ignore agent stack files")
    # SSH-form origin so github_repo_slug still resolves "McRitchie-Studio/mcritchie-studio",
    # while run_remove's `git fetch origin` can be forced offline+instant in the
    # removal tests via GIT_SSH_COMMAND=/usr/bin/false (the fetch is allow_fail and
    # base resolution only needs the local refs/remotes/origin/main set below).
    git!(@hub_dir, "remote", "add", "origin", "git@github.com:McRitchie-Studio/mcritchie-studio.git")
    git!(@hub_dir, "update-ref", "refs/remotes/origin/main", "HEAD")
    git!(@hub_dir, "worktree", "add", @worktree_dir, "-b", "feat/terminal-context")
    git!(@worktree_dir, "config", "user.email", "agent-test@example.com")
    git!(@worktree_dir, "config", "user.name", "Agent Test")
    File.write(File.join(@worktree_dir, "feature.txt"), "feature\n")
    git!(@worktree_dir, "add", "feature.txt")
    git!(@worktree_dir, "commit", "-m", "Add terminal context feature")
    write_stack_env
  end

  def write_stack_env
    File.write(File.join(@worktree_dir, ".env.agent-stack"), <<~ENVFILE)
      AGENT_WORKTREE=1
      APP_SLUG=mcritchie-studio
      TASK_SLUG=#{@task}
      APP_PORT=39999
      PORT=39999
      REDIS_URL=redis://localhost:63999/9
      DATABASE_URL=postgresql://localhost/mcritchie_studio_development_terminal_context
      TASK_RECORD_SLUG=
      TASK_URL=
      MCRITCHIE_SESSION_KEY=_studio_session_terminal_context
      LOCAL_EMAIL_CAPTURE=1
      MAIL_TRANSPORT=
      RESEND_API_KEY=
      SES_SMTP_USERNAME=
      SES_SMTP_PASSWORD=
    ENVFILE
  end

  def git!(dir, *args)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", *args, chdir: dir)
    assert status.success?, "git #{args.join(" ")} failed\n#{out}\n#{err}"
  end

  # Register refs/remotes/origin/release one commit ahead of main (a release-only
  # commit the feature branch does not carry) without disturbing the feature
  # worktree, so base resolution + ahead/behind can be exercised against release.
  def register_release_ref_ahead_of_main
    build_dir = File.join(@projects_dir, "release-build")
    git!(@hub_dir, "worktree", "add", "-b", "release-build", build_dir, "main")
    git!(build_dir, "config", "user.email", "agent-test@example.com")
    git!(build_dir, "config", "user.name", "Agent Test")
    File.write(File.join(build_dir, "release.txt"), "release\n")
    git!(build_dir, "add", "release.txt")
    git!(build_dir, "commit", "-m", "Release-only commit")
    sha, _err, status = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", "HEAD", chdir: build_dir)
    assert status.success?, "could not resolve release-build HEAD"
    git!(@hub_dir, "update-ref", "refs/remotes/origin/release", sha.strip)
    git!(@hub_dir, "worktree", "remove", build_dir, "--force")
    git!(@hub_dir, "branch", "-D", "release-build")
  end

  # Register refs/remotes/origin/accepted one commit ahead of release, so base
  # resolution can be exercised against the v2 integration branch (preferred over
  # release/main by base_ref_for).
  def register_accepted_ref_ahead_of_release
    build_dir = File.join(@projects_dir, "accepted-build")
    git!(@hub_dir, "worktree", "add", "-b", "accepted-build", build_dir, "refs/remotes/origin/release")
    git!(build_dir, "config", "user.email", "agent-test@example.com")
    git!(build_dir, "config", "user.name", "Agent Test")
    File.write(File.join(build_dir, "accepted.txt"), "accepted\n")
    git!(build_dir, "add", "accepted.txt")
    git!(build_dir, "commit", "-m", "Accepted-only commit")
    sha, _err, status = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", "HEAD", chdir: build_dir)
    assert status.success?, "could not resolve accepted-build HEAD"
    git!(@hub_dir, "update-ref", "refs/remotes/origin/accepted", sha.strip)
    git!(@hub_dir, "worktree", "remove", build_dir, "--force")
    git!(@hub_dir, "branch", "-D", "accepted-build")
  end

  def snapshot_record(registry_path)
    registry = JSON.parse(File.read(registry_path))
    registry.fetch("worktrees").find { |item| item.fetch("task") == @task }
  end

  # PUBLIC — these sit in the helper region, below the class's `private`, and Minitest
  # only collects PUBLIC test methods. Without this they are DEFINED and never RUN, and
  # a `-n /registry/` filter still reports green because it matches OTHER tests whose
  # names contain "registry". That is a test that cannot fail, reported as proof.
  public

  # ── [integration] this script writes THREE stores in the operator's real .agents ──
  #
  # The registry, the DB-allocation flock, and the elastic Redis band all resolve by
  # the same PROJECTS_DIR-else-real-root fallback that leaked the cost store (PR #525)
  # and the narration markers (PR #549). Nobody had them on a list — the containment
  # test (test/lib/state_store_containment_test.rb) found them by reading the tree.
  # The pins below were already CORRECT in this file; they were just remembered rather
  # than enforced, and a pin you have to remember is the bug. Now an unpinned spawn
  # aborts instead of overwriting the live registry every conductor session reads.
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
  # AGENT_API_SECRET from ENV → 1Password → the repo .env and dies if all three
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

  # A RUNNABLE copy of bin/agent-worktree inside the tmpdir hub; answers its path.
  #
  # This is what redirects the unpinned fallback (see the test above): ProjectsRoot
  # resolves the projects root from the running script's own location, so the copy
  # resolves @projects_dir. Three trees cover the script's require_relative graph —
  # bin/ (incl. bin/lib/projects_root), lib/ (task_usage_sandbox, claim_lease) and
  # app/models/release/ (ship_sequence, restore_primary). Copy WHOLE trees rather
  # than the five named files: a require added to the script later then keeps
  # working, and if one ever escapes these trees the child dies on a LoadError whose
  # stderr fails the /sandbox/i assertion loudly — never silently green.
  def stage_script
    FileUtils.mkdir_p(File.join(@hub_dir, "app", "models"))
    FileUtils.cp_r(Rails.root.join("bin").to_s, @hub_dir)
    FileUtils.cp_r(Rails.root.join("lib").to_s, @hub_dir)
    FileUtils.cp_r(Rails.root.join("app", "models", "release").to_s, File.join(@hub_dir, "app", "models"))
    File.join(@hub_dir, "bin", "agent-worktree")
  end

  # Child env for a spawned bin/ command: the sandbox pins, the ambient
  # agent-session vars unset (test/support/session_env.rb), and the NETWORK FLOOR
  # (test/support/outbound_seams.rb).
  #
  # THE FLOOR IS WHY THIS HELPER EXISTS RATHER THAN A HASH PER TEST. Every pin
  # below was already here except the reach ones, and their absence was not a
  # near miss: bin/agent-worktree shells the hub's bin/task on the mascot and
  # bind paths, bin/task defaults TASK_API_BASE to https://mcritchie.studio, and
  # the reads end `2>/dev/null` — so the ~11 spawn sites in this file
  # authenticated against and read the PRODUCTION BOARD, silently, on every
  # `bin/rails test`. The fixture repo also carries a real
  # git@github.com:McRitchie-Studio/... origin (setup_repo), and the sibling
  # removal tests pinned GIT_SSH_COMMAND while `finish --push --pr` did not.
  #
  # The file LOOKED sealed — several tests plant a fake bin/task in the staged hub
  # (plant_task_bin_with_lapsed_claim and friends) — and that is the lesson worth
  # keeping: those fakes seal the INSPECTED-repo read (fetch_task_record), which is
  # a different resolution from the hub CLI this script speaks through. A seam
  # spelled per test covers the tests that remember it. This one covers the file.
  #
  # OutboundSeams.env merges `extra` LAST, so a test that plants its own fake `gh`
  # on PATH, or points AGENT_WORKTREE_TASK_BIN somewhere, still wins.
  def command_env(extra = {})
    OutboundSeams.env({
      "PROJECTS_DIR" => @projects_dir,
      "AGENT_REDIS_CAPACITY_FILE" => File.join(@projects_dir, ".agents", "redis-capacity.json"),
      "AGENT_WORKTREE_LOCK" => File.join(@projects_dir, ".agents", "agent-worktree.lock"),
      "AGENT_WORKTREE_TASK_BIN" => OutboundSeams.stub("task-cli")
    }.merge(extra))
  end

  def agent_worktree(*args, chdir: Rails.root.to_s, env: {})
    Open3.capture3(command_env(env), RbConfig.ruby, @script, *args, chdir: chdir)
  end

  def agent_worktree!(*args, chdir: Rails.root.to_s, env: {})
    out, err, status = agent_worktree(*args, chdir: chdir, env: env)
    assert status.success?, "#{out}\n#{err}"
    out
  end

  def qa_intake(*args, env: {})
    Open3.capture3(command_env(env), RbConfig.ruby, Rails.root.join("bin/qa-intake").to_s, *args, chdir: Rails.root.to_s)
  end

  def write_intake_registry
    path = File.join(@projects_dir, ".agents", "intake-registry.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(
      "generated_at" => "2026-06-18T00:00:00Z",
      "apps" => [
        {
          "slug" => "mcritchie-studio",
          "display_name" => "McRitchie Studio",
          "repo" => @hub_dir,
          "primary_port" => 3000,
          "range_start" => 3000,
          "range_end" => 3099,
          "status" => "active"
        }
      ],
      "summary" => {},
      "worktrees" => [
        {
          "label" => "mcritchie-studio/terminal-context",
          "app" => "mcritchie-studio",
          "task" => @task,
          "task_record_slug" => "task-intake",
          "task_url" => "https://mcritchie.studio/tasks/task-intake",
          "worktree" => @worktree_dir,
          "health" => "down",
          "local_url" => "http://localhost:39999",
          "branch" => "feat/terminal-context",
          "dirty" => false,
          "merged_to_origin_main" => false,
          "cleanup_candidate" => false,
          "ahead_origin_main" => "1",
          "behind_origin_main" => "0",
          "issues" => []
        }
      ]
    )}\n")
    path
  end

  def write_fake_gh
    dir = File.join(@projects_dir, "fake-bin")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      if ARGV[0, 2] == ["pr", "list"]
        puts JSON.generate([
          {
            number: 41,
            title: "Terminal context marker",
            url: "https://github.com/McRitchie-Studio/mcritchie-studio/pull/41",
            isDraft: false,
            headRefName: "feat/terminal-context",
            baseRefName: "main",
            mergeStateStatus: "CLEAN",
            reviewDecision: "",
            updatedAt: "2026-06-18T00:00:00Z",
            author: { login: "agent" },
            labels: []
          }
        ])
      else
        warn "unexpected gh args: \#{ARGV.join(" ")}"
        exit 1
      end
    RUBY
    File.chmod(0o755, path)
    dir
  end
end
