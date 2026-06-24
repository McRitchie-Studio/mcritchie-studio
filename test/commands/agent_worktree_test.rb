require "test_helper"
require "erb"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
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

  test "finish push pr blocks without a bound production task" do
    out, err, status = agent_worktree("finish", "mcritchie-studio", @task, "--push", "--pr")

    assert_not status.success?
    combined = "#{out}\n#{err}"
    assert_includes combined, "not ready for QA"
    assert_includes combined, "worktree is not bound to a production McRitchie Studio task"
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
      {
        "RAILS_ENV" => "test",
        "DATABASE_URL" => "postgresql://localhost/mcritchie_studio_development_db_resolution_probe",
        "TEST_DATABASE_URL" => "postgresql://localhost/mcritchie_studio_test_db_resolution_probe",
        "PATH" => ENV.fetch("PATH", "")
      },
      RbConfig.ruby, Rails.root.join("bin/rails").to_s, "runner",
      'print ActiveRecord::Base.configurations.configs_for(env_name: "test").map(&:database).join(",")',
      chdir: Rails.root.to_s
    )

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "mcritchie_studio_test_db_resolution_probe"
    assert_no_match(/development/, out)
  end

  private

  # Load bin/agent-worktree as a library in a hermetic subprocess (the
  # $PROGRAM_NAME == __FILE__ dispatch guard keeps `load` side-effect-free) and
  # evaluate a snippet against its pure helpers. Returns stdout. Mirrors
  # force_decision/orphan_decision below.
  def script_eval(snippet)
    out, err, status = Open3.capture3(
      { "PROJECTS_DIR" => @projects_dir, "PATH" => ENV.fetch("PATH", "") },
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
      { "PROJECTS_DIR" => @projects_dir, "PATH" => ENV.fetch("PATH", "") },
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
      { "PROJECTS_DIR" => @projects_dir, "PATH" => ENV.fetch("PATH", "") },
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
      { "PROJECTS_DIR" => @projects_dir, "PATH" => ENV.fetch("PATH", "") },
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

  # Env for run_remove tests: scratch registry + offline `git fetch origin`
  # (GIT_SSH_COMMAND=/usr/bin/false makes the allow_fail fetch fail instantly with
  # no network), plus any per-test overrides (merged-PR injection, fake-gh PATH).
  def removal_env(extra = {})
    {
      "AGENT_WORKTREE_REGISTRY" => File.join(@projects_dir, ".agents", "remove-registry.json"),
      "GIT_SSH_COMMAND" => "/usr/bin/false"
    }.merge(extra)
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
    File.write(File.join(@hub_dir, ".gitignore"), ".env.agent-stack\n.agent-context.json\n")
    git!(@hub_dir, "add", ".gitignore")
    git!(@hub_dir, "commit", "-m", "Ignore agent stack files")
    # SSH-form origin so github_repo_slug still resolves "amcritchie/mcritchie-studio",
    # while run_remove's `git fetch origin` can be forced offline+instant in the
    # removal tests via GIT_SSH_COMMAND=/usr/bin/false (the fetch is allow_fail and
    # base resolution only needs the local refs/remotes/origin/main set below).
    git!(@hub_dir, "remote", "add", "origin", "git@github.com:amcritchie/mcritchie-studio.git")
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
    out, err, status = Open3.capture3("git", *args, chdir: dir)
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
    sha, _err, status = Open3.capture3("git", "rev-parse", "HEAD", chdir: build_dir)
    assert status.success?, "could not resolve release-build HEAD"
    git!(@hub_dir, "update-ref", "refs/remotes/origin/release", sha.strip)
    git!(@hub_dir, "worktree", "remove", build_dir, "--force")
    git!(@hub_dir, "branch", "-D", "release-build")
  end

  def snapshot_record(registry_path)
    registry = JSON.parse(File.read(registry_path))
    registry.fetch("worktrees").find { |item| item.fetch("task") == @task }
  end

  def command_env(extra = {})
    {
      "PROJECTS_DIR" => @projects_dir,
      "AGENT_REDIS_CAPACITY_FILE" => File.join(@projects_dir, ".agents", "redis-capacity.json"),
      "AGENT_WORKTREE_LOCK" => File.join(@projects_dir, ".agents", "agent-worktree.lock"),
      "PATH" => ENV.fetch("PATH", "")
    }.merge(extra)
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
            url: "https://github.com/amcritchie/mcritchie-studio/pull/41",
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
