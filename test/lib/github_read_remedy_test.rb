# frozen_string_literal: true

# [unit] THE PRINTED REMEDY IS EXECUTED, NOT ASSERTED.
#
# A printed remedy is a CAUSAL CLAIM — "run this and the refusal clears" — and the
# only honest test of a claim like that is to RUN IT and look at what moved. A test
# that asserts the string appears in the file is blind to the whole defect: the
# previous remedy in bin/reviewer-select was present, well-spelled, correctly
# quoted, named a real command, and refreshed the wrong variable. Every string
# assertion anyone could have written would have stayed green while an operator
# looped on it.
#
# So each case below builds the remedy the refusal prints, runs it VERBATIM in a
# shell, and then reads the environment back out of that shell. The interesting
# case is the NEGATIVE CONTROL at the bottom: the OLD remedy, run the same way,
# with the variable it leaves untouched named in the assertion. If a future edit
# points the remedy back at GH_TOKEN, that case is what reddens.
#
# NOTHING HERE REACHES 1PASSWORD OR GITHUB. bin/gh-token's cache is pinned into a
# tmpdir through TaskUsageSandboxEnv.child_env and pre-filled with a synthetic
# token, so the real command runs its real code path and returns a fake credential.
# bin/gh-auth-refresh is stubbed the way test/commands/gh_auth_refresh_test.rb
# stubs it — its own `gh` and broker hooks — for the same reason that file states:
# `gh auth login` writes the login KEYCHAIN, which GH_CONFIG_DIR does not isolate.
#
#   ruby -Itest test/lib/github_read_remedy_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "time"
require "open3"
require_relative "../support/session_env"
require_relative "../../bin/lib/github_read_remedy"

class GithubReadRemedyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "bin")

  # A synthetic credential with the real modern SHAPE (a dotted installation JWT),
  # so a redaction or a quoting bug bites on the form that actually ships rather
  # than on a tidy stub. Copied in spirit from gh_auth_refresh_test's DOTTED_TOKEN.
  CACHED_TOKEN = "ghs_16C7e42F292c6912E7710c838347Ae178B4a.eyJhbGciOiJIUzI1NiJ9.round-trip"
  STALE_READ_TOKEN = "ghs_STALE_the_read_consumes_this"

  def setup
    @dir = Dir.mktmpdir("github-read-remedy")
    @sandbox = TaskUsageSandboxEnv.child_env(@dir)

    # bin/gh-token's own cache, pre-filled so the real command answers from disk:
    # no `op`, no mint binary, no network. `created_at` is now, so the freshness
    # rule (REFRESH_AFTER_SECONDS) serves it rather than deciding to re-mint.
    store = File.join(@sandbox.fetch("CLAUDE_PROJECTS_DIR"), ".agents", "github-tokens.json")
    FileUtils.mkdir_p(File.dirname(store))
    File.write(store, JSON.generate(
      "agent" => { "active" => "a",
                   "a" => { "token" => CACHED_TOKEN, "created_at" => Time.now.utc.iso8601 } }
    ))
    File.chmod(0o600, store)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # Run +remedy+ EXACTLY as it would be pasted, then report the whole environment
  # the remedy left behind. The reader is a shell, so the test uses one.
  def follow(remedy, env = {}, probe: %w[GH_TOKEN GITHUB_TOKEN])
    probe = probe.map { |name| "#{name}=${#{name}:-}" }.join("\n")
    out, err, status = Open3.capture3(
      SessionEnv.neutralized(@sandbox.merge("GH_TOKEN" => nil, "GITHUB_TOKEN" => nil).merge(env)),
      "sh", "-c", "#{remedy}\nprintf '%s' \"#{probe}\"", chdir: ROOT
    )
    assert_predicate status, :success?, "the remedy itself failed:\n#{err}"
    out.lines.to_h { |line| line.chomp.split("=", 2) }
  end

  # --- what the remedy IS ------------------------------------------------------

  def test_the_remedy_names_an_absolute_executable_script
    command = GithubReadRemedy.refresh_command("GITHUB_TOKEN", BIN)
    script = command[/\$\((.+?)\)/, 1].to_s

    # Asks the DISK, not the string. An absolute path CONTAINS the bare form, so a
    # substring assertion here would pass on the very defect it is meant to catch —
    # measured on PR #1341 and written up in test/lib/remedy_hint_guard_test.rb.
    assert_equal File.expand_path(script), script,
                 "the remedy must name an ABSOLUTE script — a bare `bin/gh-token` typed from a " \
                 "satellite or gem desk is `No such file or directory`: #{command}"
    assert File.executable?(script), "#{script.inspect} is not an executable on this disk"
  end

  def test_the_remedy_refuses_to_compose_without_the_variable_the_read_consumes
    # The whole defect was a remedy that refreshed A variable rather than THE
    # variable. A caller that cannot say which one must not get a command back:
    # a plausible default is how the wrong spelling survives a rename.
    ["", "   ", nil].each do |blank|
      assert_raises(ArgumentError, "a blank env name must refuse, not default: #{blank.inspect}") do
        GithubReadRemedy.refresh_command(blank, BIN)
      end
    end
  end

  def test_the_failure_reason_is_squeezed_onto_one_line
    # The reason quoted into these refusals is a GitHub API error whose body is
    # multi-line JSON. Interpolated raw it breaks the indented refusal block's shape
    # and every single-line log grep over it.
    raw = %(GitHub API HTTP 401\n{"message":"Bad credentials",\n  "documentation_url":"https://docs.github.com"})

    squeezed = GithubReadRemedy.one_line(raw)

    refute_includes squeezed, "\n", "the reason must be one line"
    assert_includes squeezed, "Bad credentials", "and it must still carry what GitHub said"
    assert_equal squeezed, squeezed.strip
  end

  # --- what the remedy DOES: the round trip ------------------------------------

  # PARAMETERISED OVER THE VARIABLE NAME ON PURPOSE. Hard-coding GITHUB_TOKEN here
  # would let a remedy that ignores its argument and always writes GITHUB_TOKEN pass
  # — which is the exact class of bug (a value that looks right for the wrong
  # reason) this file exists to catch.
  def test_following_the_remedy_verbatim_sets_the_variable_it_names
    %w[GITHUB_TOKEN GH_TOKEN SOME_OTHER_READER_TOKEN].each do |name|
      remedy = GithubReadRemedy.refresh_command(name, BIN)

      env = follow(remedy, probe: %w[GH_TOKEN GITHUB_TOKEN] | [name])

      # A missing key means the PROBE broke, not the remedy, and an assertion that
      # read a nil would report the wrong failure. Say which before comparing.
      assert env.key?(name),
             "the environment probe returned no #{name} at all (got #{env.keys.sort.inspect}) — " \
             "the harness broke, so nothing here was measured"
      assert_equal CACHED_TOKEN, env.fetch(name),
                   "following #{remedy.inspect} verbatim did not set #{name}"
    end
  end

  # The case the refusal actually prints, end to end, with the STALE value present
  # before the remedy runs — because "set an unset variable" and "replace a stale
  # one" are different acts, and only the second is what an operator is doing.
  def test_the_remedy_replaces_a_stale_value_in_the_variable_the_read_consumes
    remedy = GithubReadRemedy.refresh_command("GITHUB_TOKEN", BIN)

    env = follow(remedy, { "GITHUB_TOKEN" => STALE_READ_TOKEN })

    assert_equal CACHED_TOKEN, env.fetch("GITHUB_TOKEN"),
                 "the remedy must REPLACE the stale credential, not merely coexist with it"
    refute_equal STALE_READ_TOKEN, env.fetch("GITHUB_TOKEN"), "the stale token survived the remedy"
  end

  # === THE NEGATIVE CONTROL =====================================================
  #
  # THE DEFECT, RUNNABLE. `eval "$(bin/gh-auth-refresh --export)"` was printed by
  # both of bin/reviewer-select's credential refusals. Its entire stdout contract is
  # one line — `export GH_TOKEN='…'` (bin/gh-auth-refresh:209) — so it repairs the
  # credential `gh` reads and leaves GITHUB_TOKEN, which is what
  # Github::AppToken#resolve returns when App creds are absent, exactly as stale as
  # it was. The operator followed it verbatim and got the byte-identical refusal.
  #
  # This is not here as history. It is the assertion that reddens if anyone points a
  # remedy for a Ruby-side GitHub read back at GH_TOKEN, and it is stated as the
  # measurement it is: both halves named, so a reader can see WHICH variable moved.
  def test_the_old_remedy_does_not_touch_the_variable_the_read_consumes
    gh = File.join(@dir, "gh-stub")
    File.write(gh, <<~SH)
      #!/bin/sh
      if [ "$1" = "auth" ] && [ "$2" = "login" ]; then cat > "#{@dir}/keyring"; exit 0; fi
      if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
        [ -f "#{@dir}/keyring" ] || exit 1
        cat "#{@dir}/keyring"; exit 0
      fi
      exit 2
    SH
    broker = File.join(@dir, "broker-stub")
    File.write(broker, "#!/bin/sh\necho ghs_stub_broker_agent\n")
    [gh, broker].each { |path| File.chmod(0o755, path) }

    old_remedy = %(eval "$(#{File.join(BIN, "gh-auth-refresh")} --export)")

    env = follow(old_remedy,
                 { "GH_AUTH_REFRESH_GH_BIN" => gh,
                   "GH_AUTH_REFRESH_TOKEN_BIN" => broker,
                   "GH_TOKEN" => "ghs_STALE_gh_reads_this",
                   "GITHUB_TOKEN" => STALE_READ_TOKEN })

    assert_equal "ghs_stub_broker_agent", env.fetch("GH_TOKEN"),
                 "the control is only a control if the old remedy DID do its own job"
    assert_equal STALE_READ_TOKEN, env.fetch("GITHUB_TOKEN"),
                 "MEASURED: gh-auth-refresh --export moves GH_TOKEN and leaves GITHUB_TOKEN — the " \
                 "variable Github::AppToken consumes — untouched. That is why it cannot be the " \
                 "remedy for a Ruby-side GitHub read."
  end
end
