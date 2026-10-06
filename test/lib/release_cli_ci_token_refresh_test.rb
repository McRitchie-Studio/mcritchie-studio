# frozen_string_literal: true

# The release gem gate holds a pending CI verdict PAST one App token's hour and still
# passes on green (task ci-poll-refreshes-its-token).
#
# THE DEFECT. The gate may now hold a pending verdict for ~105 minutes
# (bin/lib/ci_poll_budget.rb), but CiStatus minted its read token once per process and
# an installation token lives 3600 s. Past the hour every read came back 401, the
# verdict turned :unreadable, and the gate aborted with a credentials message.
#
# THE REAL bin/release gem gate runs in the harness subprocess. Only the edges are
# stubbed: `gh` (CI_STATUS_GH_BIN), the token broker (GH_AUTH_TOKEN_BIN), and the clock
# (CiStatus.clock, advanced 20 minutes per CI read). The stub gh enforces the expiry
# itself: it refuses a token 3600 simulated seconds after the broker minted it, and
# reports CI pending until 100 minutes in, then green.
#
# A new file beside its subcommand, over the shared harness:
#   ruby -Itest test/lib/release_cli_ci_token_refresh_test.rb

require_relative "release_cli_harness"
require_relative "../../bin/lib/ci_poll_budget"

class ReleaseCliCiTokenRefreshTest < ReleaseCliHarness
  CONSUMER_CI = <<~YAML
    name: Consumer CI
    on: [push]
    jobs:
      consumer-tests:
        runs-on: ubuntu-latest
        timeout-minutes: 95
  YAML

  READ_STEP_S = 1200
  GREEN_AT_S = 6000

  # [integration] THE ACCEPTANCE: pending past the token's age, then green, passes.
  def test_the_gem_gate_stays_pending_past_the_token_age_then_passes_on_green
    Dir.mktmpdir do |dir|
      out = gem_gate(dir)

      assert_includes out, "RESULT=nil", "a wait past one token's hour must still pass on green: #{out}"
      assert_includes out, "READS=5", "read 4 (80 min) needs a token minted after the first expired"
      assert_includes out, "MINTS=2"
      assert_match(/re-minted the GitHub App read token \(\d+ chars\)/, out)
      refute_includes out, "ghs_stub", "the token itself must never reach the gate's output"
    end
  end

  # THE STUB BITES: when the broker can mint only once, the same wait reads the 401 the
  # unfixed gate always met, and the gate fails closed on it. Without this, the case
  # above could pass on a stub that never expired anything.
  def test_without_a_second_mint_the_expired_token_aborts_the_gate
    Dir.mktmpdir do |dir|
      out = gem_gate(dir, mint_limit: 1)

      assert_includes out, "NOTHING WAS PUBLISHED"
      assert_includes out, "unreadable"
      assert_includes out, "READS=4"
    end
  end

  private

  def gem_gate(dir, mint_limit: 99)
    repo, sha = workflow_repo(dir)
    state = File.join(dir, "state")
    FileUtils.mkdir_p(state)
    File.write(File.join(state, "now"), "0")
    File.write(File.join(state, "tokens"), "")
    gh = stub(dir, "gh", gh_script(state))
    broker = stub(dir, "broker", broker_script(state, mint_limit))

    run_ruby(<<~RUBY)
      ENV["RELEASE_CI_POLL_INTERVAL"] = "0"
      ENV["RELEASE_CI_POLL_TIMEOUT"] = "0"
      ENV.delete("RELEASE_CI_STATUS")
      ENV.delete("GH_TOKEN")
      ENV.delete("GH_APP_ITEM")
      ENV["CI_STATUS_GH_BIN"] = #{gh.inspect}
      ENV["GH_AUTH_TOKEN_BIN"] = #{broker.inspect}
      ARGV.replace([])
      load #{BIN.inspect}
      def repo_path(_repo) = #{repo.inspect}
      def repo_name_with_owner(_repo) = "McRitchie-Studio/studio-engine"
      $sim = 0
      $ci_reads = 0
      CiStatus.reset_gh_auth!
      CiStatus.clock = -> { $sim }
      alias real_ci_verdict ci_verdict
      def ci_verdict(repo, sha)
        $ci_reads += 1
        $sim += #{READ_STEP_S}
        File.write(#{File.join(state, 'now').inspect}, $sim.to_s)
        real_ci_verdict(repo, sha)
      end
      puts "RESULT=\#{gem_ci_failure("studio-engine", #{sha.inspect}, "0.99.0").inspect}"
      puts "READS=\#{$ci_reads}"
      puts "MINTS=\#{File.readlines(#{File.join(state, 'tokens').inspect}).size}"
    RUBY
  end

  def workflow_repo(dir)
    repo = File.join(dir, "gem")
    FileUtils.mkdir_p(File.join(repo, ".github", "workflows"))
    system("git", "init", "-q", repo, out: File::NULL, err: File::NULL) || flunk("git init failed")
    File.write(File.join(repo, ".github", "workflows", "consumer-ci.yml"), CONSUMER_CI)
    run_git(repo, "add", ".")
    run_git(repo, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init")
    [repo, git_out(repo, "rev-parse", "HEAD")]
  end

  # GitHub, reduced to what this case needs: a token is good for 3600 s from its mint,
  # and the SHA's one check run is in progress until GREEN_AT_S.
  def gh_script(state)
    <<~SH
      #!/bin/sh
      now=$(cat "#{state}/now")
      minted=$(awk -v t="$GH_TOKEN" '$1 == t { print $2 }' "#{state}/tokens")
      if [ -z "$GH_TOKEN" ] || [ -z "$minted" ] || [ $(( now - minted )) -ge 3600 ]; then
        echo '{"message":"Bad credentials","status":"401"}'
        echo 'gh: Bad credentials (HTTP 401)' >&2
        exit 1
      fi
      if [ "$now" -ge #{GREEN_AT_S} ]; then
        echo '{"total_count":1,"check_runs":[{"name":"consumer-ci","status":"completed","conclusion":"success"}]}'
      else
        echo '{"total_count":1,"check_runs":[{"name":"consumer-ci","status":"in_progress","conclusion":null}]}'
      fi
    SH
  end

  def broker_script(state, limit)
    <<~SH
      #!/bin/sh
      n=$(( $(wc -l < "#{state}/tokens") + 1 ))
      [ "$n" -gt #{limit} ] && { echo 'no 1Password session' >&2; exit 1; }
      echo "ghs_stub$n $(cat "#{state}/now")" >> "#{state}/tokens"
      printf 'ghs_stub%s' "$n"
    SH
  end

  def stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end
end
