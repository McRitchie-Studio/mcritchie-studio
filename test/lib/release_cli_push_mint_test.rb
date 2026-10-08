# frozen_string_literal: true

# The ship's push to main: the deployer pre-mint and the network classification.
#
# Run directly:
#   ruby -Itest test/lib/release_cli_push_mint_test.rb

require_relative "release_cli_harness"

class ReleaseCliPushMintTest < ReleaseCliHarness
  # A broker script standing in for bin/gh-token: it logs its argv and runs `body`.
  def push_broker(dir, body)
    File.join(dir, "broker").tap do |path|
      File.write(path, "#!/bin/sh\necho \"$@\" >> #{File.join(dir, 'mints')}\n#{body}\n")
      File.chmod(0o755, path)
    end
  end

  # `sh` that records each push with the GH_TOKEN it was handed, and succeeds.
  def push_recorder(dir, broker)
    <<~RUBY
      ENV["GH_AUTH_TOKEN_BIN"] = #{broker.inspect}
      ENV["GH_TOKEN"] = "aged-ambient-token"
      ENV.delete("GH_APP_ITEM")
      def repo_path(_repo) = #{dir.inspect}
      def advance_accepted(*) = nil
      def sleep(seconds) = puts("SLEEP \#{seconds}")
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        puts("PUSH mints_so_far=\#{File.readlines(#{File.join(dir, 'mints').inspect}).size} " \\
             "token=\#{(env || {})['GH_TOKEN'].inspect}") if cmd.include?("push")
        ["", true]
      end
    RUBY
  end

  PUSH_CALL = %{begin; %s; puts("PASSED"); rescue SystemExit => e; puts("ABORTED: " + e.message); end}

  # [unit] One mint per push, as the deployer whatever GH_APP_ITEM says, before the push.
  def test_push_premints_deployer
    Dir.mktmpdir do |dir|
      broker = push_broker(dir, "echo fresh-token")
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{push_frozen_main("sibling", "a" * 40)}))

      assert_includes out, "PASSED", out
      assert_equal ["--identity deployer --force"], File.readlines(File.join(dir, "mints"), chomp: true),
                   "exactly one mint, naming the deployer"
      assert_includes out, %(PUSH mints_so_far=1 token="fresh-token"), "the mint precedes the push and rides it"
      refute_includes out, "SLEEP", "a first-try mint does not wait"
    end
  end

  # [unit] An aged launch token: every push carries its own fresh mint, never the ambient one.
  def test_an_aged_ambient_token_never_rides_a_push
    Dir.mktmpdir do |dir|
      broker = push_broker(dir, %(echo "fresh-$(wc -l < #{File.join(dir, 'mints')} | tr -d ' ')"))
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{%w[hub turf].each { |r| push_frozen_main(r, "a" * 40) }}))

      assert_includes out, %(PUSH mints_so_far=1 token="fresh-1")
      assert_includes out, %(PUSH mints_so_far=2 token="fresh-2"), "the second push re-mints: #{out}"
      refute_includes out, %(token="aged-ambient-token")
    end
  end

  # [unit] A mint that fails once is retried after five seconds, and the push proceeds.
  def test_a_failed_mint_retries_once_then_pushes
    Dir.mktmpdir do |dir|
      mints = File.join(dir, "mints")
      broker = push_broker(dir, %(if [ "$(wc -l < #{mints} | tr -d ' ')" = "1" ]; then echo "op: timeout" >&2; exit 1; fi\necho fresh-token))
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{push_frozen_main("sibling", "a" * 40)}))

      assert_equal 1, out.scan("SLEEP 5").size, "one wait of five seconds: #{out}"
      assert_includes out, %(PUSH mints_so_far=2 token="fresh-token")
      assert_includes out, "PASSED"
    end
  end

  # [unit] Two failed mints abort before the push; a DNS cause is named as the network.
  def test_a_mint_failing_twice_on_dns_aborts_naming_the_network
    Dir.mktmpdir do |dir|
      broker = push_broker(dir, %(echo "gh-token: getaddrinfo: nodename nor servname provided, or not known" >&2; exit 1))
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{push_frozen_main("sibling", "a" * 40)}))

      assert_includes out, "ABORTED", out
      assert_equal 2, File.readlines(File.join(dir, "mints")).size, "one mint and one retry, no more"
      assert_equal 1, out.scan("SLEEP 5").size
      refute_includes out, "PUSH ", "the push is not attempted without a token"
      assert_includes out, "deployer mint said: gh-token: getaddrinfo", "the mint's own words reach the log"
      assert_includes out, "NETWORK failure"
      refute_includes out, "REFUSED ON CREDENTIALS"
    end
  end

  # The control: a mint that fails for another reason is not called a network failure.
  def test_a_mint_failing_twice_for_another_reason_names_the_mint
    Dir.mktmpdir do |dir|
      broker = push_broker(dir, %(echo "gh-token: 1Password read failed for item github.mcritchie-admin" >&2; exit 1))
      out = run_cli(["--yes"], setup: push_recorder(dir, broker),
                    call: format(PUSH_CALL, %{push_frozen_main("sibling", "a" * 40)}))

      assert_includes out, "ABORTED", out
      assert_includes out, "could not mint the DEPLOYER token"
      assert_includes out, "deployer mint said: gh-token: 1Password read failed"
      refute_includes out, "NETWORK failure"
      refute_includes out, "PUSH "
    end
  end

  # --- the classifier ---

  # A helper that cannot resolve its host leaves git saying `could not read
  # Username`, an auth sign; the network line beside it decides.
  def test_dns_failure_classifies_network
    dns = <<~GIT
      gh-app-git-credential: getaddrinfo: nodename nor servname provided, or not known
      fatal: could not read Username for 'https://github.com': terminal prompts disabled
    GIT
    assert_equal "network", eval_helper(%(classify_push_failure(#{dns.inspect})))
    assert_equal "network",
                 eval_helper(%(classify_push_failure("fatal: unable to access 'https://github.com/x/y/': Could not resolve host: github.com")))
    assert_equal "network",
                 eval_helper(%(classify_push_failure("fatal: unable to access 'https://github.com/x/y/': Operation timed out")))

    # The controls: the same refusals with no network line stay auth.
    assert_equal "auth",
                 eval_helper(%(classify_push_failure("fatal: could not read Username for 'https://github.com': terminal prompts disabled")))
    assert_equal "auth", eval_helper(%(classify_push_failure("remote: Invalid username or token.")))
  end

  def test_the_network_message_prescribes_neither_standard_remedy
    msg = eval_helper(%(push_failure_message("mcritchie-studio", "a" * 40, :network)))

    assert_includes msg, "NETWORK failure"
    assert_includes msg, "not a credential refusal and not a divergence"
    assert_includes msg, "do NOT re-run `prepare`"
    refute_includes msg, "REFUSED ON CREDENTIALS"
  end
end
