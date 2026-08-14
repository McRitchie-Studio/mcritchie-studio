# frozen_string_literal: true

# bin/dor-check's PR FILE-LIST read, and the credential expiry that used to make it
# lie. Standalone (no Rails — it shells out to the script with --file fixtures):
#   ruby -Itest test/lib/dor_check_pr_files_auth_test.rb
#
# THE DEFECT. `pr_changed_files` made its own gh call with `err: File::NULL` and
# `return nil unless $?.success?`. GitHub App installation tokens live ~1 hour, so
# mid-session that read started failing — and BOTH halves of the failure were
# invisible:
#   1. nil is also what "this PR has no files" returns, so the resolver fell through
#      to the LOCAL git diff and the gate went on to reason about the working tree
#      while printing a verdict about "the PR". Shape tiers, the doc-only exemption
#      and migration detection all judged a different artifact, with no signal.
#   2. gh prints "Bad credentials (HTTP 401)" on STDERR, which File::NULL discarded —
#      so there was no text left for GhAuthRetry.auth_failure? or
#      CiStatus.unreadable_cause to classify. The failure could not even be NAMED,
#      let alone recovered by the mint-once-and-retry seam bin/ship and bin/pr-review
#      have used since PR 832.
#
# EVERY TEST HERE DRIVES THE REAL READ. No DOR_CHECK_PR_FILES injection: the gh
# binary is stubbed through the seam's own CI_STATUS_GH_BIN, and the token broker
# through GH_AUTH_TOKEN_BIN, so the whole chain runs — subprocess, stderr capture,
# classification, mint, retry — without a network, a real token, or 1Password. A test
# that asserted against the injection seam alone would never have watched the
# unguarded version fall back, which is the one thing worth proving.
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class DorCheckPrFilesAuthTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  MINTED = "stub-minted-token"
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/77"

  # The local working tree the gate must NOT silently substitute for the PR: ONE
  # doc file. It is doc-only on purpose — that is what buys a `kind: chore` the
  # doc-only exemption, which is the shape the 2026-08-08 false pass wore.
  LOCAL_DOC = "docs/agents/notes.md"

  # ── the fixtures ────────────────────────────────────────────────────────────

  def chore_task(pr: PR_URL)
    {
      "slug" => "task-pr-read", "title" => "T",
      "metadata" => { "devops" => {
        "kind" => "chore",
        "pr_url" => pr,
        "acceptance" => ["read the PR's diff"],
        "repositories" => ["myapp"],
        "risk_tags" => ["gate-integrity"],
        "test_plan" => ["[unit] resolver"],
        "post_deploy_cmd" => "none",
        "checks_run" => []
      }.compact }
    }
  end

  # A real git repo carrying ONE untracked doc file — the local view.
  def with_local_tree
    Dir.mktmpdir do |dir|
      git = ->(a) { assert(system("git -C #{dir} #{a} >/dev/null 2>&1"), "git #{a}") }
      git.call("init -q")
      git.call("config user.email t@example.com")
      git.call("config user.name t")
      git.call("commit -q --allow-empty -m init")
      FileUtils.mkdir_p(File.join(dir, File.dirname(LOCAL_DOC)))
      File.write(File.join(dir, LOCAL_DOC), "notes\n")
      yield dir
    end
  end

  # `mode` drives the stub gh:
  #   "auth"     — refuse with a 401 on STDERR unless the MINTED token is in its env
  #                (the live failure, and the recovery, in one stub)
  #   "hard401"  — refuse with a 401 always, whatever token it is handed
  #   "notfound" — a 404 on stderr: a failure that is NOT a credential refusal
  #   "ok"       — print the PR's file list
  # `broker`: :working mints MINTED, :broken cannot mint (the operator with no
  # 1Password session — gh's ORIGINAL refusal must then reach the reader).
  def with_stubs(mode:, broker: :broken)
    Dir.mktmpdir do |dir|
      calls = File.join(dir, "gh-calls.log")
      mints = File.join(dir, "mint-calls.log")
      [calls, mints].each { |f| File.write(f, "") }

      gh = write_script(dir, "gh-stub", <<~SH)
        #!/bin/sh
        echo "gh $*" >> "$GH_STUB_CALLS"
        case "$GH_STUB_MODE" in
          ok) echo "app/services/charge.rb"; echo "app/models/order.rb"; exit 0 ;;
          notfound) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
          apibody)
            # What `gh api` REALLY does on a 401: GitHub's JSON error body on stdout,
            # gh's own status line on stderr. Both, verbatim, from the live API.
            printf '{\\n  "message": "Bad credentials",\\n  "status": "401"\\n}\\n'
            echo 'gh: Bad credentials (HTTP 401)' >&2
            exit 1 ;;
          auth)
            if [ "$GH_TOKEN" = "$GH_STUB_TOKEN" ]; then
              echo "app/services/charge.rb"; echo "app/models/order.rb"; exit 0
            fi
            echo 'gh: Bad credentials (HTTP 401)' >&2
            exit 1 ;;
          *) echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1 ;;
        esac
      SH

      broker_stub = write_script(dir, "gh-token-stub", <<~SH)
        #!/bin/sh
        echo "mint $*" >> "$GH_MINT_CALLS"
        #{broker == :working ? "printf '%s' \"$GH_STUB_TOKEN\"; exit 0" : "echo 'no 1Password session' >&2; exit 1"}
      SH

      yield({
        "CI_STATUS_GH_BIN" => gh,
        "GH_AUTH_TOKEN_BIN" => broker_stub,
        "GH_STUB_CALLS" => calls,
        "GH_MINT_CALLS" => mints,
        "GH_STUB_MODE" => mode,
        "GH_STUB_TOKEN" => MINTED,
        # The stale ambient credential itself, set explicitly so the test never
        # depends on what the developer's shell happens to be carrying.
        "GH_TOKEN" => "stale-ambient-token"
      }, calls, mints)
    end
  end

  def write_script(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  # Run dor-check against `root` with the gh stubs wired. Returns [verdict, code].
  def dor_check(task, root, stub_env, *args)
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task))
      env = SessionEnv.neutralized(stub_env.merge(
        "DOR_CHECK_DIFF_ROOT" => root,
        "DOR_CHECK_DIFF_BASE" => "HEAD",
        # The REAL PR read is the subject — both injection seams stay OFF.
        "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_PR_FILES" => nil,
        "DOR_CHECK_CI_STATUS" => "green",
        "DOR_CHECK_SUITE_EVIDENCE" => "ok"
      ))
      out = IO.popen(env, "#{BIN} --file #{path} --json #{args.join(" ")} 2>/dev/null", &:read)
      [JSON.parse(out), $?.exitstatus]
    end
  end

  # ── [unit] the classification: a refusal is not an empty PR ─────────────────

  def test_a_refused_read_is_classified_as_a_credential_fault
    # HALF 2 OF THE DEFECT. With stderr discarded there was nothing to classify, so
    # the refusal could only ever be an anonymous "no files". The 401 the stub prints
    # goes to STDERR ALONE — if the read stops capturing it, `cause` cannot be
    # "credentials" and this reddens.
    with_local_tree do |root|
      with_stubs(mode: "hard401") do |env, calls, mints|
        verdict, code = dor_check(chore_task, root, env, "--gate-role", "review")

        assert_equal 1, code, verdict.inspect
        assert_equal "unreadable", verdict.dig("pr_read", "state"),
                     "a refused read must classify as unreadable, not fall through as an empty PR"
        assert_equal "credentials", verdict.dig("pr_read", "cause"),
                     "the 401 arrives on STDERR — classifying it proves stderr was preserved"
        assert_match(/Bad credentials/, verdict.dig("pr_read", "reason").to_s)
        refute_empty File.read(calls), "the read must actually have gone through the gh seam"
        refute_empty File.read(mints), "a credential refusal must reach the mint-once-and-retry recovery"
      end
    end
  end

  def test_the_reason_is_githubs_sentence_not_the_first_byte_of_its_json
    # MEASURED against the live API with GH_TOKEN=invalid_token, which is the only way
    # this surfaced: `gh api` prints GitHub's JSON error BODY on stdout, so a
    # first-line reason renders the refusal as "REFUSED on credentials ({)" — a
    # verdict that names a fault and then tells the reader nothing about it. The
    # sentence GitHub actually sent is in `message`.
    with_local_tree do |root|
      with_stubs(mode: "apibody") do |env, _calls, _mints|
        verdict, = dor_check(chore_task, root, env, "--gate-role", "review")

        assert_equal "Bad credentials", verdict.dig("pr_read", "reason"),
                     "the reason must be GitHub's sentence, not the opening brace of its JSON body"
        assert_equal "credentials", verdict.dig("pr_read", "cause")
      end
    end
  end

  def test_a_non_auth_failure_is_not_dressed_up_as_a_credential_fault
    # NARROW ON PURPOSE, the same way CiStatus.unreadable_cause is: a 404 keeps its
    # :unverified meaning. A gate that cried "fix your token" at every missing PR
    # would teach the reader to ignore the one time it matters.
    with_local_tree do |root|
      with_stubs(mode: "notfound") do |env, _calls, mints|
        verdict, = dor_check(chore_task, root, env, "--gate-role", "review")

        assert_equal "unverified", verdict.dig("pr_read", "state")
        assert_nil verdict.dig("pr_read", "cause")
        assert_empty File.read(mints), "a non-auth failure must NOT burn a mint — re-running it just fails slower"
      end
    end
  end

  # ── [integration] the local diff is never substituted in silence ────────────

  def test_review_role_refuses_rather_than_grading_the_local_tree
    # THE REGRESSION, in the shape that actually fired: `kind: chore`, an unreadable
    # PR, and a local tree holding one harmless doc file. Before this fix the gate
    # read that file, found it non-behavioral, and printed
    # "✓ DoR-to-Merge n/a … doc-only diff … → ready to advance" for a PR whose
    # contents it had never seen.
    with_local_tree do |root|
      with_stubs(mode: "hard401") do |env, _calls, _mints|
        verdict, code = dor_check(chore_task, root, env, "--gate-role", "review")

        assert_equal 1, code, "an unreadable PR must not advance a review: #{verdict["note"]}"
        refute verdict["ready"]
        refute verdict["exempt"], "THE BUG: the doc-only exemption granted off a tree nobody asked about"
        assert_equal "pr_unreadable", verdict["diff_source"],
                     "the refusal is its own source — not 'nothing was readable anywhere'"
        refute_includes Array(verdict["changed_files"]).to_s, LOCAL_DOC,
                        "the local file must never stand in for the PR's file list here"
        assert_match(/REFUSED on credentials/, verdict["note"].to_s)
        assert_match(/gh-auth-refresh/, verdict["note"].to_s, "the refusal must carry THE ONE remedy string")
      end
    end
  end

  def test_submit_side_still_uses_the_local_view_but_says_so
    # The builder stands in the task's OWN worktree, their verdict is provisional,
    # and review re-reads it — so an hour-old token must not block every handoff.
    # What it must not do is stay QUIET: the exemption still lands, and it lands
    # carrying the reason the PR was not read.
    with_local_tree do |root|
      with_stubs(mode: "hard401") do |env, _calls, _mints|
        verdict, code = dor_check(chore_task, root, env)

        assert_equal 0, code, "submit-side must keep working with a stale token: #{verdict["note"]}"
        assert verdict["exempt"]
        assert_equal "git", verdict["diff_source"], "the local view is what was graded, and it says so"
        assert_equal "unreadable", verdict.dig("pr_read", "state"),
                     "a degraded verdict must be machine-readable as degraded"
        assert_match(/REFUSED on credentials/, verdict["note"].to_s,
                     "THE BUG: the substitution happened with nothing said about it")
        assert(verdict["suggestions"].any? { |s| s =~ /gh-auth-refresh/ },
               "the remedy rides with the degraded verdict")
      end
    end
  end

  # ── [integration] the recovery, and the paths that must stay quiet ──────────

  def test_a_stale_credential_is_recovered_through_the_shared_seam
    # THE PAYOFF of adopting the seam instead of re-rolling the call: the stub gh
    # refuses the ambient token and accepts the minted one, so passing requires the
    # WHOLE chain — classify the refusal, mint once, hand the token to the RETRIED
    # child, re-read. The PR's real files then gate the chore, which is what the
    # 401 was hiding.
    with_local_tree do |root|
      with_stubs(mode: "auth", broker: :working) do |env, _calls, mints|
        verdict, code = dor_check(chore_task, root, env, "--gate-role", "review")

        assert_equal 1, code, "the PR ships code — recovering the read must GATE it"
        assert_equal "pr", verdict["diff_source"], "the recovered read is the PR's own file list"
        assert_includes Array(verdict["changed_files"]), "app/services/charge.rb"
        assert_nil verdict["pr_read"], "a recovered read is not a degraded verdict"
        refute_empty File.read(mints), "recovery means a mint actually happened"
      end
    end
  end

  def test_a_successful_read_gates_on_the_prs_own_files
    with_local_tree do |root|
      with_stubs(mode: "ok") do |env, _calls, mints|
        verdict, code = dor_check(chore_task, root, env, "--gate-role", "review")

        assert_equal 1, code
        assert_equal "pr", verdict["diff_source"]
        assert_includes Array(verdict["changed_files"]), "app/models/order.rb"
        assert_nil verdict["pr_read"], "a healthy read stays silent"
        assert_empty File.read(mints), "a call that succeeds never mints"
      end
    end
  end

  def test_a_task_with_no_pr_yet_reads_nothing_and_says_nothing
    # THE OFFLINE PATH, kept intact. A pre-PR task has nothing to read: it must not
    # shell gh at all, must not raise an alert, and must go on grading the local
    # tree exactly as it always has. "No PR yet" and "GitHub refused us" are the two
    # facts this change exists to separate — proving the quiet one stayed quiet is
    # half of that.
    with_local_tree do |root|
      with_stubs(mode: "hard401") do |env, calls, mints|
        verdict, code = dor_check(chore_task(pr: nil), root, env)

        assert_equal 0, code, verdict.inspect
        assert verdict["exempt"], "a doc-only chore with no PR is still exempt"
        assert_equal "git", verdict["diff_source"]
        assert_nil verdict["pr_read"], "no PR is not a failed read"
        assert_empty verdict["suggestions"], "nothing failed, so there is nothing to warn about"
        assert_empty File.read(calls), "with no pr_url there is nothing to ask GitHub"
        assert_empty File.read(mints)
      end
    end
  end
end
