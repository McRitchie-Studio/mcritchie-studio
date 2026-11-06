# frozen_string_literal: true

# bin/release's long-lived `gh` calls ride a refreshing token: the workflow dispatch, the
# watch and its polls, the batch-PR merge and create. Writes that must not run twice
# (gh_write_once) read GitHub's state before any retry. Stubbed edges only: `sh` and
# `bounded_capture2e` (gh), the broker (GH_AUTH_TOKEN_BIN, numbered tokens), the clock
# (CiStatus.clock). Calls are logged as "<verb>:<token>", never the token itself.
#   ruby -Itest test/lib/release_cli_gh_write_refresh_test.rb
# History: task release-writes-refresh-tokens.

require_relative "release_cli_harness"

class ReleaseCliGhWriteRefreshTest < ReleaseCliHarness
  EXPIRED = "HTTP 401: Bad credentials (https://api.github.com/graphql)\nTry authenticating with:  gh auth login"
  PR = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/9"

  # The fake GitHub. $expired lists the token labels gh refuses ("ambient" = no GH_TOKEN).
  # $refuse[verb] counts refusals to give that verb whatever its token; $effect[verb]
  # makes a refused write take effect anyway (the 401 came after the act).
  GITHUB = <<~'RUBY'
    def sleep(*) = nil
    def dispatch_correlation_id = "dw-test"
    def repo_name_with_owner(_repo) = "McRitchie-Studio/mcritchie-studio"
    $sim = 0
    CiStatus.reset_gh_auth!
    CiStatus.clock = -> { $sim }
    $calls = []
    $expired = ["ambient"]
    $refuse = Hash.new(0)
    $effect = {}
    $fail = {}
    $down = {}
    $registered = false
    $pr_state = "OPEN"
    $open_pr = ""
    def tok(env) = (t = (env || {})["GH_TOKEN"]) ? "mint#" + t.delete_prefix("ghs_stub_") : "ambient"
    def gh_answer(verb, env)
      $calls << "#{verb}:#{tok(env)}"
      if $refuse[verb].positive?
        $refuse[verb] -= 1
        $effect[verb]&.call
        return [EXPIRED, false]
      end
      return [EXPIRED, false] if $expired.include?(tok(env))
      return [$fail[verb], false] if $fail[verb]
      return ["HTTP 502: Bad Gateway", false] if $down[verb]

      yield
    end
    def sh(*cmd, env: nil, **)
      verb = cmd[0, 3].join(" ")
      verb = "gh run snapshot" if verb == "gh run list" && !cmd.include?("--event")
      case verb
      when "gh run snapshot" then gh_answer(verb, env) { ["100", true] }
      when "gh run list" then gh_answer(verb, env) { [$registered ? "101" : "", true] }
      when "gh workflow run" then gh_answer(verb, env) { $registered = true; ["", true] }
      when "gh run watch" then ($on_watch&.call; gh_answer(verb, env) { ["", !$watch_dies] })
      when "gh run view" then gh_answer(verb, env) { ["completed\tsuccess", true] }
      when "gh run rerun" then gh_answer(verb, env) { ["", true] }
      when "gh pr merge" then ($merged = cmd; gh_answer(verb, env) { $pr_state = "MERGED"; ["merged", true] })
      when "gh pr list" then gh_answer(verb, env) { [$open_pr, true] }
      when "gh pr create" then gh_answer(verb, env) { $open_pr = PR_URL; [PR_URL, true] }
      else ["", true]
      end
    end
    GhStubStatus = Struct.new(:ok) { def success? = ok }
    alias real_bounded_capture2e bounded_capture2e
    def bounded_capture2e(*cmd, env: nil, **opts)
      return real_bounded_capture2e(*cmd, env: env, **opts) unless cmd[0, 3] == ["gh", "pr", "view"]

      out, ok = gh_answer("gh pr view", env) { [$pr_state, true] }
      [out, GhStubStatus.new(ok)]
    end
  RUBY

  REPORT = %(\nputs "CALLS=\#{$calls.inspect}"\n)

  def with_broker(lane: nil)
    Dir.mktmpdir do |dir|
      broker = File.join(dir, "gh-token")
      File.write(broker, "#!/bin/sh\nn=$(( $(cat #{dir}/n 2>/dev/null || echo 0) + 1 ))\necho $n > #{dir}/n\n" \
                         "echo \"$@\" >> #{dir}/args\necho ghs_stub_$n\n")
      File.chmod(0o755, broker)
      env = %(ENV["GH_AUTH_TOKEN_BIN"] = #{broker.inspect}; ENV["GH_APP_ITEM"] = #{lane.inspect}; PR_URL = #{PR.inspect}; EXPIRED = #{EXPIRED.inspect}\n)
      yield(env + GITHUB, -> { File.exist?("#{dir}/args") ? File.read("#{dir}/args") : "" })
    end
  end

  def drive(setup, call)
    out = run_cli([], setup: setup, call: %(begin; r = #{call}; puts("RESULT=\#{r.inspect}"); ) +
                                      %(rescue SystemExit => e; puts("ABORTED \#{e.message}"); end) + REPORT)
    refute_includes out, "ghs_stub", "a token must never be printed"
    out
  end

  def calls(out) = out[/^CALLS=(.*)$/, 1]

  DISPATCH = %(dispatch_and_watch("qa-deploy.yml", { "sha" => "0a0cc23" }))

  # [unit] THE DISPATCH: refused on credentials, nothing happened → one re-mint, GitHub read, one retry.
  def test_a_refused_dispatch_that_did_nothing_is_retried_once_on_a_fresh_token
    with_broker do |gh, _args|
      out = drive(gh + %($expired = []; $refuse["gh workflow run"] = 1), DISPATCH)

      assert_includes out, "RESULT=true", out
      assert_equal 2, calls(out).scan("gh workflow run").size, out
      assert_includes calls(out), %("gh workflow run:ambient", "gh run list:mint#1"), out
      assert_includes calls(out), %("gh workflow run:mint#1"), out
      assert_includes out, "GitHub shows it did not happen", out
    end
  end

  # [unit] The 401 came AFTER the run was created: GitHub shows our run, so it is never re-dispatched.
  def test_a_refused_dispatch_that_took_effect_is_not_repeated
    with_broker do |gh, _args|
      out = drive(gh + %($expired = []; $refuse["gh workflow run"] = 1; $effect["gh workflow run"] = -> { $registered = true }),
                DISPATCH)

      assert_includes out, "RESULT=true", out
      assert_equal 1, calls(out).scan("gh workflow run").size, "a second dispatch is a second deploy: #{out}"
      assert_includes out, "took effect — not repeating it", out
      assert_includes calls(out), "gh run watch", out
    end
  end

  # [unit] Refused, and GitHub unreadable after the mint: not repeated, and not called "nothing deployed".
  def test_a_refused_dispatch_with_unreadable_state_fails_without_a_retry
    with_broker do |gh, _args|
      out = drive(gh + %($expired = []; $refuse["gh workflow run"] = 1; $effect["gh workflow run"] = -> { $down["gh run list"] = true }),
                DISPATCH)

      assert_includes out, "RESULT=false", out
      assert_equal 1, calls(out).scan("gh workflow run").size, out
      assert_includes out, "NOT KNOWN whether a run was created", out
      refute_includes out, "NOTHING WAS DEPLOYED", out
      refute_includes calls(out), "gh run watch", out
    end
  end

  # [unit] A failure that is not about credentials mints nothing and is never retried.
  def test_a_non_credential_dispatch_failure_is_not_retried
    with_broker do |gh, args|
      out = drive(gh + %($expired = []; $fail["gh workflow run"] = "HTTP 500: Internal Server Error"), DISPATCH)

      assert_includes out, "RESULT=false", out
      assert_equal 1, calls(out).scan("gh workflow run").size, out
      assert_includes out, "NOTHING WAS DEPLOYED", out
      assert_empty args.call, "no token was minted"
    end
  end

  # [unit] THE WATCH OUTLIVES ITS TOKEN: mint#1 dies mid-watch (past its hour); the poll re-mints and resumes.
  def test_a_watch_that_outlives_its_token_resumes_on_a_fresh_one
    with_broker do |gh, _args|
      setup = gh + %($expired = []; CiStatus.mint_gh_token!; ) +
              %($on_watch = -> { $sim = 3_700; $expired << "mint#1"; $watch_dies = true; $on_watch = nil })
      out = drive(setup, DISPATCH)

      assert_includes out, "RESULT=true", out
      assert_includes calls(out), %("gh run watch:mint#1", "gh run view:mint#2"), out
      assert_equal 1, calls(out).scan("gh workflow run").size, out
    end
  end

  # [unit] A token refused mid-watch BEFORE it aged (revoked): the poll's refusal re-mints once and retries.
  def test_a_watch_whose_token_is_refused_early_resumes_after_one_re_mint
    with_broker do |gh, _args|
      setup = gh + %($expired = []; CiStatus.mint_gh_token!; ) +
              %($on_watch = -> { $sim = 1_000; $expired << "mint#1"; $watch_dies = true; $on_watch = nil })
      out = drive(setup, DISPATCH)

      assert_includes out, "RESULT=true", out
      assert_includes calls(out), %("gh run watch:mint#1", "gh run view:mint#1", "gh run view:mint#2"), out
    end
  end

  # [unit] An aging held token is re-minted BEFORE the lane's calls, so the dispatch and watch never ride it.
  def test_an_aging_token_is_re_minted_before_the_dispatch_and_the_watch
    with_broker do |gh, _args|
      out = drive(gh + %($expired = ["ambient", "mint#1"]; CiStatus.mint_gh_token!; $sim = 3_300), DISPATCH)

      assert_includes out, "RESULT=true", out
      refute_includes calls(out), "mint#1", out
      assert_includes calls(out), %("gh workflow run:mint#2"), out
      assert_includes calls(out), %("gh run watch:mint#2"), out
    end
  end

  # [unit] THE LANE: a ship (GH_APP_ITEM=admin) re-mints the deployer; a prepare (unset) the agent.
  def test_the_re_mint_keeps_the_lane_identity
    { "github.mcritchie-admin" => "--identity deployer", nil => "--identity agent" }.each do |lane, identity|
      with_broker(lane: lane) do |gh, args|
        out = drive(gh, DISPATCH)

        assert_includes out, "RESULT=true", out
        assert_includes args.call, identity, "lane #{lane.inspect}: #{args.call}"
      end
    end
  end

  MERGE = %(merge_batch_pr(#{PR.inspect}, "abc1234"))

  # [unit] THE MERGE: refused on the expired ambient token, the PR still OPEN → one retry, still pinned.
  def test_a_refused_merge_on_an_open_pr_is_retried_once_pinned
    with_broker do |gh, _args|
      out = drive(gh, MERGE + %(.tap { puts "PINNED=\#{$merged.include?("abc1234")}" }))

      assert_includes out, 'RESULT=["merged", true]', out
      assert_includes calls(out), %("gh pr merge:ambient", "gh pr view:mint#1", "gh pr merge:mint#1"), out
      assert_includes out, "PINNED=true", out
    end
  end

  # [unit] Refused, but GitHub shows the PR MERGED: not merged again, and reported ok.
  def test_a_refused_merge_that_landed_is_not_repeated
    with_broker do |gh, _args|
      out = drive(gh + %($refuse["gh pr merge"] = 1; $expired = []; $effect["gh pr merge"] = -> { $pr_state = "MERGED" }), MERGE)

      assert_includes out, 'RESULT=["", true]', out
      assert_equal 1, calls(out).scan("gh pr merge").size, out
    end
  end

  # [unit] Refused, and the PR's state unreadable after the mint: no retry, a failure that says why.
  def test_a_refused_merge_with_unreadable_state_is_not_retried
    with_broker do |gh, _args|
      out = drive(gh + %($refuse["gh pr merge"] = 1; $expired = []; $down["gh pr view"] = true), MERGE)

      assert_includes out, "RESULT=[", out
      assert_includes out, ", false]", out
      assert_equal 1, calls(out).scan("gh pr merge").size, out
      assert_includes out, "it is NOT repeated", out
    end
  end

  # [unit] A merge conflict is not a credential refusal: no mint, no state read, no retry.
  def test_a_non_credential_merge_failure_is_not_retried
    with_broker do |gh, args|
      out = drive(gh + %($expired = []; $fail["gh pr merge"] = "Pull request is not mergeable: merge conflict"), MERGE)

      assert_equal 1, calls(out).scan("gh pr merge").size, out
      refute_includes calls(out), "gh pr view", out
      assert_empty args.call, "no token was minted"
    end
  end

  CREATE = %(accepted_release_pr_url("mcritchie-studio"))

  # [unit] THE CREATE: the list read re-mints on the expired ambient token; the create rides the fresh one.
  def test_the_batch_pr_read_and_create_ride_the_refreshed_token
    with_broker do |gh, _args|
      out = drive(gh, CREATE)

      assert_includes out, "RESULT=#{PR.inspect}", out
      assert_includes calls(out), %("gh pr list:ambient", "gh pr list:mint#1", "gh pr create:mint#1"), out
    end
  end

  # [unit] Refused, nothing created → one retry; refused but created → the open PR is reused, no retry.
  def test_a_refused_create_retries_only_when_github_shows_no_pr
    with_broker do |gh, _args|
      out = drive(gh + %($expired = []; $refuse["gh pr create"] = 1), CREATE)

      assert_includes out, "RESULT=#{PR.inspect}", out
      assert_equal 2, calls(out).scan("gh pr create").size, out
    end
    with_broker do |gh, _args|
      out = drive(gh + %($expired = []; $refuse["gh pr create"] = 1; $effect["gh pr create"] = -> { $open_pr = PR_URL }), CREATE)

      assert_includes out, "RESULT=#{PR.inspect}", out
      assert_equal 1, calls(out).scan("gh pr create").size, "a second create would duplicate the PR: #{out}"
    end
  end

  # [unit] Refused with the list unreadable → abort, no retry; a non-credential failure → abort, no mint.
  def test_a_create_that_cannot_be_checked_or_failed_on_the_work_is_not_retried
    with_broker do |gh, _args|
      out = drive(gh + %($expired = []; $refuse["gh pr create"] = 1; $effect["gh pr create"] = -> { $down["gh pr list"] = true }), CREATE)

      assert_includes out, "ABORTED", out
      assert_equal 1, calls(out).scan("gh pr create").size, out
    end
    with_broker do |gh, args|
      out = drive(gh + %($expired = []; $fail["gh pr create"] = "GraphQL: Head sha can't be blank"), CREATE)

      assert_includes out, "ABORTED", out
      assert_equal 1, calls(out).scan("gh pr create").size, out
      assert_empty args.call, "no token was minted"
    end
  end

  RERUN = %(gh_sh_refreshing("gh", "run", "rerun", "11"))

  # [unit] CARL'S NOTE: a CI read minted 10s ago, so the floor stops a second mint. The message says
  # the refused call rode a fresh token, and quotes no stale broker error as the reason.
  def test_a_floored_mint_after_a_fresh_one_names_the_real_cause
    with_broker do |gh, _args|
      setup = gh + %(CiStatus.mint_gh_token!; $sim = 10; $expired << "mint#1"; ) +
              %(GhAuthRetry.instance_variable_set(:@last_error, "op: stale session from an hour ago"))
      out = drive(setup, RERUN)

      assert_includes out, "on a token minted 10s ago, so this is not an expired token", out
      refute_includes out, "no fresh token could be minted", out
      refute_includes out, "stale session", out
    end
  end

  # [unit] The floor after a FAILED mint names that failure and its age, not a fresh attempt.
  def test_a_floored_mint_after_a_failed_one_says_the_last_mint_failed
    with_broker do |gh, _args|
      setup = gh + %(ENV["GH_AUTH_TOKEN_BIN"] = "/nonexistent/gh-token"; CiStatus.mint_gh_token!; $sim = 10)
      out = drive(setup, RERUN)

      assert_includes out, "the last mint, 10s ago, failed", out
      refute_includes out, "no fresh token could be minted", out
    end
  end
end
