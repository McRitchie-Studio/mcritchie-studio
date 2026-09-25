# frozen_string_literal: true

# THE AGENT-WORKTREE DESK FIXTURE — stage a real desk, drive the real binary.
#
# Extracted from test/commands/agent_worktree_test.rb, which had grown to 2,513 lines
# and had twice raised its own append ceiling in config/test_health.yml rather than
# split. The ceiling asks new tests to go to a NEW FILE; the reason they kept not going
# was this harness. A `cleanup` question is only worth asking against a desk that is
# staged, aged, bound to a task and merged onto its base, and re-staging that from
# scratch makes the DUPLICATED FIXTURE — not the one variable a new test flips — the
# thing a reader has to verify. So the fixture moved instead of the tests.
#
# USE IT — a second test file needs no copying, only this:
#
#   require "test_helper"
#   require_relative "../support/agent_worktree_fixture"
#
#   class MyAgentWorktreeThingTest < ActiveSupport::TestCase
#     include AgentWorktreeFixture
#
#     test "[integration] cleanup spares a desk whose task is mid-release" do
#       mark_worktree_merged_to_origin_main
#       bind_task_slug("mid-release-task")
#       abandon_desk!                       # call it LAST: anything written after re-ages it
#
#       out, _err, status = agent_worktree("cleanup", "mcritchie-studio",
#                                          env: { "AGENT_WORKTREE_TASK_JSON" => board_record_at("reviewed") })
#
#       assert status.success?
#       assert_includes out, "withheld mcritchie-studio/terminal-context"
#       assert_includes out, "board stage `reviewed`"
#     end
#   end
#
# ASSERT THE REASON, NOT THE PREFIX — that second line is not decoration. The sweep prints
# `withheld <desk>` for EVERY hold it takes (fresh, dirty, claimed, unreadable, board
# stage), so a test that asserts only the prefix passes no matter which channel held the
# desk, and therefore cannot prove the thing it was written to prove. Assert the reason.
# Same discipline with `rev` below: it RAISES on a ref that does not resolve, so assert the
# SHA shape (`assert_match(/\A[0-9a-f]{40}\z/, rev(...))`) rather than `refute_empty` —
# `git rev-parse <missing-ref>` prints the ref NAME and exits 128, so "not empty" is true
# for a ref that is not there. `head_branch` RAISES for the same reason and was repaired
# the same way: on an UNBORN HEAD `git rev-parse --abbrev-ref HEAD` prints the literal
# "HEAD" and exits 128, so a dropped status hands back a branch name that is not one.
#
# `include` is the whole setup. The module owns `setup`/`teardown`; a host that needs
# its own must call `super`, or call the two primitives
# (`stage_agent_worktree_desk!` / `teardown_agent_worktree_desk!`) directly.
#
# WHAT THE DESK IS, once staged. Five ivars, and host tests read them freely:
#
#   @projects_dir   the throwaway projects root (realpath'd — /var and /tmp are symlinks
#                   on macOS, and registered_worktree? compares paths by exact string)
#   @hub_dir        <projects>/mcritchie-studio — the primary checkout, on `main`
#   @task           "terminal-context", the one desk this fixture stages
#   @worktree_dir   <hub>/.worktrees/terminal-context, on feat/terminal-context
#   @script         the REAL bin/agent-worktree under test (not a copy; `stage_script`
#                   makes a copy when a test needs the script to resolve OUR root)
#   @desk_ledger    a live localhost board (DeskLedgerSink) — see the note on setup
#
# WHAT STAYED BEHIND, deliberately: the containment SELF-TESTS' apparatus in
# test/commands/agent_worktree_test.rb (SINK_HOST, PIN_PROOF_SECRET, SENTINEL,
# sink_requests). Those exist to prove THAT FILE's network floor holds, and their
# comments are the proof's reasoning; moving them would separate the evidence from the
# claim. Everything a test needs to ASK A QUESTION is here.
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "uri"
require_relative "desk_ledger_sink"

module AgentWorktreeFixture
  # Minitest lifecycle. A host with its own setup/teardown calls `super`, or calls the
  # two primitives below directly.
  def setup
    stage_agent_worktree_desk!
  end

  def teardown
    teardown_agent_worktree_desk!
  end

  def stage_agent_worktree_desk!
    # realpath so derived paths match git's canonical worktree-list output on
    # macOS (/var and /tmp are symlinks into /private), which registered_worktree?
    # compares by exact string.
    @projects_dir = File.realpath(Dir.mktmpdir("agent-worktree-command"))
    @hub_dir = File.join(@projects_dir, "mcritchie-studio")
    @task = "terminal-context"
    @worktree_dir = File.join(@hub_dir, ".worktrees", @task)
    @script = Rails.root.join("bin/agent-worktree").to_s
    # THE DESK LEDGER, for real. `remove`/`cleanup --reclaim --yes` file their audit record
    # on the board BEFORE they destroy anything and ABORT when they cannot — so under the
    # OutboundSeams floor (TASK_API_BASE pinned unroutable) no teardown staged here could
    # complete. The answer is a real board on localhost, not a test-only bypass: a skip flag
    # on a destroy path is how a fail-closed guard quietly stops being one.
    @desk_ledger = DeskLedgerSink.start
    setup_repo
  end

  def teardown_agent_worktree_desk!
    @desk_ledger&.stop
    FileUtils.rm_rf(@projects_dir) if @projects_dir
  end

  # ── THE STAGED HUB AND ITS ONE DESK ───────────────────────────────────────────
  #
  # A throwaway <tmpdir>/mcritchie-studio git repo with a real `.worktrees/terminal-context`
  # worktree cut off it, an ssh-form GitHub origin, and a `refs/remotes/origin/main` — the
  # shape `bin/agent-worktree` expects to find on the operator's machine. Everything below
  # either stages more of that world or asks the real script a question about it.

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
    # /.env* as the real repos have it: `new`/bind-task also write .env.development.local
    # (and .env.test.local), which must not read as uncommitted work either.
    File.write(File.join(@hub_dir, ".gitignore"), "/.env*\n.agent-context.json\n/.worktrees/\n")
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
  #
  # `dir:` defaults to the fixture task desk; the release WORKSPACES (`_ship`/`_gate`) are
  # staged as their own desks and need the same aging, or the desk channel withholds them
  # for being newborn and the channel actually under test never speaks.
  def abandon_desk!(age_seconds: 3 * 24 * 60 * 60, dir: @worktree_dir)
    at = Time.now - age_seconds
    paths = Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH)
                .reject { |path| %w[. ..].include?(File.basename(path)) }
    (paths + [dir]).each do |path|
      File.utime(at, at, path)
    rescue SystemCallError
      nil # a path that raced away is not the point of the fixture
    end
    assert_operator Time.now - File.mtime(File.join(dir, ".git")), :>,
                    ClaimLease::DESK_IDLE_SECONDS,
                    "premise: the desk must read as older than the idle window"
  end

  # A `_ship` workspace as bin/release makes one: a fixed-path, DETACHED checkout under
  # .worktrees, carrying no branch and no bound task. Aged, so the desk channel does not
  # withhold it for being young — the release-claim channel is what is under test.
  def stage_ship_workspace!
    dir = File.join(@hub_dir, ".worktrees", "_ship")
    git!(@hub_dir, "worktree", "add", "--detach", dir, "main")
    abandon_desk!(dir: dir)
    dir
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

  # ── DRIVING THE REAL BINARY ───────────────────────────────────────────────────
  #
  # Every spawn goes through `command_env`, which carries the sandbox pins AND the network
  # floor. Nothing in a host test file should build a child env by hand — that is exactly
  # how the ~11 spawn sites this fixture came from once read the production board.

  # Child env for a spawned bin/ command: the sandbox pins, the ambient
  # agent-session vars unset (test/support/session_env.rb), and the NETWORK FLOOR
  # (test/support/outbound_seams.rb).
  #
  # THE FLOOR IS WHY THIS HELPER EXISTS RATHER THAN A HASH PER TEST. Every pin
  # below was already here except the reach ones, and their absence was not a
  # near miss: bin/agent-worktree shells the hub's bin/task on the mascot and
  # bind paths, bin/task defaults TASK_API_BASE to https://mcritchie.studio, and
  # the reads end `2>/dev/null` — so the ~11 spawn sites this fixture was
  # extracted from authenticated against and read the PRODUCTION BOARD, silently, on every
  # `bin/rails test`. The fixture repo also carries a real
  # git@github.com:McRitchie-Studio/... origin (setup_repo), and the sibling
  # removal tests pinned GIT_SSH_COMMAND while `finish --push --pr` did not.
  #
  # THAT file LOOKED sealed — several of its tests plant a fake bin/task in the staged hub
  # (plant_task_bin_with_lapsed_claim and friends) — and that is the lesson worth
  # keeping: those fakes seal the INSPECTED-repo read (fetch_task_record), which is
  # a different resolution from the hub CLI this script speaks through. A seam
  # spelled per test covers the tests that remember it. This one covers every spawn any
  # file makes through the fixture — which is the reason the floor belongs HERE and not
  # in the test file it came from.
  #
  # OutboundSeams.env merges `extra` LAST, so a test that plants its own fake `gh`
  # on PATH, or points AGENT_WORKTREE_TASK_BIN somewhere, still wins.
  def command_env(extra = {})
    OutboundSeams.env({
      "PROJECTS_DIR" => @projects_dir,
      "AGENT_REDIS_CAPACITY_FILE" => File.join(@projects_dir, ".agents", "redis-capacity.json"),
      "AGENT_WORKTREE_LOCK" => File.join(@projects_dir, ".agents", "agent-worktree.lock"),
      # The fixture origin is an ssh URL and OutboundSeams pins GIT_SSH_COMMAND to a
      # stub that always exits non-zero, so a REAL `git fetch origin` can never
      # succeed here on any machine. Without this default every sweep driven through
      # this fixture takes the origin-unreachable WITHHOLD branch instead of the channel the test
      # was written to exercise. Override it per-test (`"error"`/`"gone"`) to drive
      # the withhold path deliberately.
      "AGENT_WORKTREE_ORIGIN_FETCH" => "ok",
      "AGENT_WORKTREE_TASK_BIN" => OutboundSeams.stub("task-cli")
    }.merge(@desk_ledger.env).merge(extra))
  end

  def agent_worktree(*args, chdir: Rails.root.to_s, env: {})
    Open3.capture3(command_env(env), RbConfig.ruby, @script, *args, chdir: chdir)
  end

  def agent_worktree!(*args, chdir: Rails.root.to_s, env: {})
    out, err, status = agent_worktree(*args, chdir: chdir, env: env)
    assert status.success?, "#{out}\n#{err}"
    out
  end

  # Env for run_remove tests: scratch registry, plus any per-test overrides
  # (merged-PR injection, fake-gh PATH).
  #
  # GIT_SSH_COMMAND used to be pinned here, at "/usr/bin/false", and that pin is
  # the reason the agent-worktree suite's ssh containment was believed to be handled: it made the
  # allow_fail `git fetch origin` fail instantly with no network — for the REMOVAL
  # tests, and only for them. The `finish --push --pr` test in
  # test/commands/agent_worktree_test.rb passed no env at all, against a fixture whose origin is a real
  # git@github.com:McRitchie-Studio/... URL. So the pin now lives in the floor
  # (OutboundSeams, via command_env), where it covers every spawn any test makes, and
  # what it points at is a RECORDING refusal rather than /usr/bin/false — same
  # instant failure, but it leaves a receipt, so a test can prove the interception
  # happened instead of inferring it from the absence of a hang.
  def removal_env(extra = {})
    { "AGENT_WORKTREE_REGISTRY" => File.join(@projects_dir, ".agents", "remove-registry.json") }.merge(extra)
  end

  # Force the ssh-form origin fetch to fail instantly offline (restore is then
  # against the local origin/main ref). command_env's floor already pins this for
  # every spawn the fixture makes; naming it at a call site keeps the premise
  # legible where the assertion depends on the fetch NOT succeeding.
  def offline_git
    { "GIT_SSH_COMMAND" => OutboundSeams.stub("ssh") }
  end

  def qa_intake(*args, env: {})
    Open3.capture3(command_env(env), RbConfig.ruby, Rails.root.join("bin/qa-intake").to_s, *args, chdir: Rails.root.to_s)
  end

  # A RUNNABLE copy of bin/agent-worktree inside the tmpdir hub; answers its path.
  #
  # This is what redirects the unpinned fallback (the unpinned-registry check in
  # test/commands/agent_worktree_test.rb): ProjectsRoot
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

  # ── THE BOARD STAND-INS — claims, stages, and fake `bin/task` plants ──────────
  #
  # Two ways to answer the script's board read: `AGENT_WORKTREE_TASK_JSON` (a payload, for
  # a single read) and a planted `bin/task` in the fixture hub (a script, for a read whose
  # ANSWER CHANGES or whose call count is the evidence).

  # --- reclaim guard: a live-claimed builder desk is never destroyed ----------
  # A fresh worktree and a fast-forward-merged one are git-identical (clean, HEAD == base,
  # 0-ahead), so ONLY the task's live build-claim (ClaimLease) separates a desk a builder
  # just sat down at from finished work. The claim is read through the same board seam as
  # the PR autofill; AGENT_WORKTREE_TASK_JSON stands in for the board's task record.
  # The lease TTL is 120s (ClaimLease::DEFAULT_TTL_SECONDS).
  CLAIM_TTL = 120

  # WHY EVERY BOARD PAYLOAD IN THE RECLAIM CHECKS NAMES A `stage`. The board-stage channel
  # (added 2026-09-20) withholds a desk whose bound task has not reached `shipped` or
  # `archived`, and it reads a record carrying NO stage as an unanswered question rather
  # than a clean one — a real task record always has a stage, so its absence means the
  # payload is not one. On a destroy path that is the right posture, and it makes a
  # stage-less fixture an INCOMPLETE board record rather than a minimal one: it would be
  # withheld as `:stageless` before the channel a check is named for is ever consulted.
  # `shipped` is what a finished, reclaimable desk's task actually carries, so naming it
  # here makes these stand-ins more faithful to the board, not less. The stage channel's
  # own checks drive the non-terminal stages.
  TERMINAL_STAGE = "shipped"

  def claim_json(expires_at, session:)
    JSON.generate("stage" => TERMINAL_STAGE, "metadata" => { "devops" => {
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
    JSON.generate("stage" => TERMINAL_STAGE, "metadata" => { "devops" => {
                    "claimed_session" => "sess-corrupt", "claim_expires_at" => "not-a-timestamp"
                  } })
  end

  def board_record_at(stage)
    JSON.generate("stage" => stage, "review_in_progress" => false,
                  "metadata" => { "devops" => JSON.parse(lapsed_claim_json).dig("metadata", "devops") })
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
        echo '{"stage":"shipped","metadata":{"devops":{}}}'
      else
        echo '{"stage":"shipped","metadata":{"devops":{"claimed_session":"sess-midsweep","claim_expires_at":"#{expires}"}}}'
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
      echo '{"stage":"shipped","metadata":{"devops":{"claimed_session":"sess-dead","claim_expires_at":"#{expires}"}}}'
    SH
    FileUtils.chmod(0o755, bin)
    counter
  end

  # A `bin/task` that speaks the board's genuine 404 contract: EXIT_TASK_NOT_FOUND (4) plus
  # the tasks API's own body. That pair is the ONLY thing the gate accepts as "the task does
  # not exist" — a router or route 404 is a failed read and stays in the unreadable lane.
  def plant_task_bin_answering_not_found
    bin = File.join(@hub_dir, "bin", "task")
    FileUtils.mkdir_p(File.dirname(bin))
    File.write(bin, <<~SH)
      #!/bin/sh
      echo 'GET /api/v1/tasks/deleted-task -> 404: task not found' >&2
      exit 4
    SH
    FileUtils.chmod(0o755, bin)
  end

  # ── STUB BINARIES ON THE CHILD'S PATH ─────────────────────────────────────────
  #
  # Planted FIRST on PATH so they win over the OutboundSeams refusal stub — the point is to
  # drive the REAL `gh pr list` code path, argv and JSON parsing included, not to bypass it.

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

  # A `gh` that answers the two PR lookups this script makes, and nothing else. `open_pr:`
  # is the number an OPEN-state query returns, or nil for "nothing open". Planted FIRST on
  # the child's PATH so it wins over the OutboundSeams refusal stub — the point is to drive
  # the REAL `gh pr list` code path, argv and JSON parsing included, not to bypass it.
  def write_fake_gh_pr_state(open_pr:)
    dir = File.join(@projects_dir, "fake-bin-open-pr-#{open_pr || "none"}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      if ARGV[0, 2] == ["pr", "list"]
        state = ARGV.include?("--state") ? ARGV[ARGV.index("--state") + 1] : nil
        open_pr = #{open_pr.inspect}
        puts(state == "open" && open_pr ? %([{"number":\#{open_pr}}]) : "[]")
      else
        warn "unexpected gh args: \#{ARGV.join(" ")}"
        exit 1
      end
    RUBY
    File.chmod(0o755, path)
    dir
  end

  # The release-claim CLI the reclaim guard shells for "is a release conductor working?".
  # Answers per ROLE, which is the whole point: exit 0 = a live claim, exit 3 = the board
  # answered "none". Lives at the real path the script resolves inside the fixture hub.
  def write_fake_release_claim_cli(live_roles:)
    path = File.join(@hub_dir, "bin", "lib", "release_claim_cli.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      # Fixture release-claim CLI: `any-live --role <role>` only.
      role = ARGV.include?("--role") ? ARGV[ARGV.index("--role") + 1] : nil
      exit(#{live_roles.inspect}.include?(role) ? 0 : 3)
    RUBY
    path
  end

  # ── READING BACK WHAT THE SCRIPT WROTE ────────────────────────────────────────
  #
  # Inspectors, not assertions. `git_dirty?` in particular is usually used to PIN A PREMISE
  # rather than to assert a result — a check about a clean-yet-occupied desk proves nothing
  # if the fixture quietly went dirty.

  def snapshot_record(registry_path)
    registry = JSON.parse(File.read(registry_path))
    registry.fetch("worktrees").find { |item| item.fetch("task") == @task }
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

  # RAISES on a HEAD that does not resolve, for the reason `rev` does below.
  #
  # AN UNBORN HEAD IS THE SILENT CASE. In a repo with no commits `git rev-parse
  # --abbrev-ref HEAD` writes the literal "HEAD" to stdout and exits 128 (measured
  # 2026-09-22), so a helper that drops the status hands back a plausible branch name
  # for a repo that has none. The six ASSERTING call sites all happen to be
  # `assert_equal` against a named branch, which makes "HEAD" loud at each of them —
  # but that loudness is a property of those six assertions, not of this helper, and
  # the next caller to ask `head_branch(dir) == whatever` inherits the silence
  # instead. The control below drives the helper itself.
  def head_branch(dir)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse",
                                      "--abbrev-ref", "HEAD", chdir: dir)
    unless status.success?
      raise "git rev-parse --abbrev-ref HEAD failed in #{dir} (exit #{status.exitstatus}): #{err.strip}"
    end

    out.strip
  end

  # RAISES on a ref that does not resolve, and that is the whole point.
  #
  # `git rev-parse <missing-ref>` writes the REF NAME to stdout and exits 128. So a
  # helper that drops the status returns "refs/remotes/origin/main" for a ref that
  # is not there — never nil, never empty. `refute_empty rev(...)` could therefore
  # not fail, on exactly the case it was written to catch (measured 2026-09-21).
  #
  # THE CALLER THAT MADE IT DANGEROUS IS `mark_worktree_merged_to_origin_main`, and
  # the danger is not the shape this note used to describe. It named
  # `stage_agent_worktree_desk!`, which never calls `rev` at all, and it called the
  # failure "a bare ref NAME reaching update-ref" — which is LOUD, and therefore the
  # one shape that needed no guard: measured 2026-09-22, `update-ref
  # refs/remotes/origin/main refs/heads/no-such` dies with `fatal:
  # refs/heads/no-such: not a valid SHA1`.
  #
  # THE SILENT PATH IS THE ONE THE CODE TAKES. The call is `rev(@worktree_dir,
  # "HEAD")`; a status-dropping helper returns the literal string "HEAD"; and
  # `update-ref refs/remotes/origin/main HEAD` run in the HUB SUCCEEDS, because HEAD
  # re-resolves there. Measured on a throwaway hub+worktree pair the same day:
  # origin/main landed on the HUB head, not the worktree head, exit 0, no output. The
  # ref is then wrong, and 39 tests in test/commands/agent_worktree_test.rb build
  # their "clean and landed on base" premise on it (`grep -c
  # mark_worktree_merged_to_origin_main test/commands/agent_worktree_test.rb`,
  # 2026-09-22 — re-derive it rather than trusting this number).
  #
  # RAISING BEATS RETURNING NIL: nil reaches git as `update-ref ""` and surfaces as a
  # `git!` assertion reading `fatal: : not a valid SHA1`, which names neither the ref
  # nor the directory.
  def rev(dir, ref)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", ref, chdir: dir)
    unless status.success?
      raise "git rev-parse #{ref.inspect} failed in #{dir} (exit #{status.exitstatus}): #{err.strip}"
    end

    out.strip
  end

  # Mirrors the script's own dirtiness test. Used to PIN a premise rather than to assert a
  # result: a check about a desk that is clean-yet-occupied proves nothing if the fixture
  # quietly went dirty, because dirtiness disqualifies a desk from reclaim on its own.
  def git_dirty?(dir)
    out, = Open3.capture3(SessionEnv.neutralized, "git", "status", "--porcelain", chdir: dir)
    !out.strip.empty?
  end

  # ── THE SCRIPT'S PURE FUNCTIONS, DRIVEN AS A LIBRARY ──────────────────────────
  #
  # `load` in a hermetic subprocess: the script's `$PROGRAM_NAME == __FILE__` dispatch guard
  # keeps the load side-effect-free, so a pure decision can be driven with no filesystem and
  # no board at all.

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

  # ── POSTGRES, FOR THE DB-PROVISIONING CHECKS ──────────────────────────────────
  #
  # Derived from whichever connection URL this machine actually has; blank means no database
  # is reachable and the CALLER skips.

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
end
