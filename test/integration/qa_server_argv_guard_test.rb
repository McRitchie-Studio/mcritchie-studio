# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"
require Rails.root.join("bin", "lib", "qa_server_cli").to_s

# [integration] bin/qa-server's ARGUMENT GUARD, driven through the REAL script.
#
# THE DEFECT (/tasks/qa-server-help-provisions). The dispatcher deleted `--yes` to
# set assume_yes and then called `run_provision(ARGV[0])`; `--help` was never
# inspected and simply fell off the end of the line. So
#
#     bin/qa-server provision <app> --yes --help
#
# PROVISIONED A QA SERVER FOR REAL: `heroku create`, `heroku addons:create`
# (billable), `heroku domains:add`, `certs:auto:enable`, and a config-var PATCH
# carrying real secrets — with the confirmation ALREADY SUPPRESSED by the `--yes`
# beside it. `deploy <app> <ref> --yes --help` was the same shape one argument over:
# it force-pushed to the QA app's Heroku remote and scaled its dynos.
#
# WHY THIS FILE NEVER RUNS A MUTATING SUBCOMMAND. The thing under test creates
# billable infrastructure when probed, so "run it and see" is the one experiment
# that must never be performed: if the guard has regressed, the probe IS the
# provision, and there is no dry-run to hide behind. config/test_health.yml already
# records what the cheaper version of this mistake cost — two under-stubbed tests
# once ran bin/clean-artifacts and bin/archive-docs FOR REAL against a developer's
# machine. So the verdict is proven two ways, neither of which can mutate:
#
#   1. THE REAL METHOD, DRIVEN DIRECTLY. A bare ruby subprocess `load`s
#      bin/qa-server — which does NOT dispatch when it is not $PROGRAM_NAME — and
#      calls `guard_argv!` with an injected exiter. That is the production method
#      reading the production dictionary (QaServerCli::COMMANDS), with the `case`
#      statement never reached.
#
#   2. ONE REAL EXECUTION, of the ONLY subcommand that cannot mutate. `bin/qa-server
#      list` reads config/qa_environments.yml and prints it — no Heroku call, no
#      git, no network. It is therefore the single command whose worst case, the
#      guard having regressed, is a local file read. That execution is what proves
#      the SCRIPT is guarded, rather than merely owning a guard method nothing calls.
#
#   ruby -Itest test/integration/qa_server_argv_guard_test.rb
class QaServerArgvGuardTest < ActionDispatch::IntegrationTest
  QA_SERVER = Rails.root.join("bin", "qa-server")

  # bin/qa-server is plain Ruby with NO bundler — every probe below runs it the way
  # an operator's shell does. Inheriting the suite's RUBYOPT would re-enter bundler
  # in the child and bury the verdict under a page of warnings.
  BARE = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze

  def bare_env = SessionEnv.neutralized(BARE)

  # Drive the REAL `guard_argv!` for each command line, in a subprocess that loads
  # bin/qa-server WITHOUT dispatching. Returns one result hash per line:
  #   exit — the code the guard exited with, or "returned" when it let the
  #          dispatcher proceed (a clean line, or a token that is not a subcommand)
  def guard(*command_lines)
    script = <<~RUBY
      require "json"
      require "stringio"
      # `load`, not `require`: the file has no .rb extension. It does not dispatch,
      # because __FILE__ is this path and $PROGRAM_NAME is the -e script.
      load #{QA_SERVER.to_s.inspect}

      results = #{JSON.dump(command_lines)}.map do |argv|
        out = StringIO.new
        err = StringIO.new
        code = "returned"
        catch(:guarded) do
          guard_argv!(argv, out: out, err: err, exiter: ->(c) { code = c; throw :guarded, c })
        end
        { "argv" => argv, "exit" => code, "out" => out.string, "err" => err.string }
      end
      puts JSON.dump(results)
    RUBY

    out, status = Open3.capture2(bare_env, RbConfig.ruby, "-e", script)
    assert status.success?, "the guard probe itself failed to run:\n#{out}"
    JSON.parse(out.lines.last)
  end

  def one(argv) = guard(argv).first

  # --- 1. the real method, dispatcher never reached ---------------------------

  # THE regression, driven through the production guard.
  test "provision --yes --help refuses through the real guard and provisions nothing" do
    result = one(%w[provision turf-monster --yes --help])

    assert_equal 1, result["exit"], "help must exit 1 — never 0, which bin/release reads as success"
    assert_match(/provision <app>/, result["err"])
    assert_empty result["out"], "an exit-1 answer must not be printed to stdout as though it succeeded"
  end

  test "deploy --yes --help refuses through the real guard and pushes nothing" do
    result = one(%w[deploy turf-monster origin/main --yes --help])

    assert_equal 1, result["exit"]
    assert_match(/NOTHING was pushed/, result["err"] + result["out"],
                 "the operator's question after a refusal is whether the push happened")
  end

  # Every subcommand, both help spellings, from a position AFTER a real argument —
  # the position the old parser dropped.
  test "every subcommand answers help in trailing position without acting" do
    QaServerCli::COMMANDS.each_key do |cmd|
      %w[--help -h].each do |flag|
        result = one([cmd, "turf-monster", flag])

        assert_equal 1, result["exit"], "bin/qa-server #{cmd} turf-monster #{flag} must answer help"
      end
    end
  end

  test "an argument no subcommand accounts for refuses with exit 2" do
    result = one(%w[provision turf-monster --force])

    assert_equal 2, result["exit"]
    assert_match(/unrecognized argument "--force"/, result["err"])
  end

  # The other half, and the one that wedges a lane if it is wrong: the real calls
  # must still be handed to the dispatcher. bin/release.rb:3198 shells the deploy
  # line on every `prepare`.
  test "the documented invocations are still handed to the dispatcher" do
    lines = [
      %w[list],
      %w[plan turf-monster],
      %w[status mcritchie-studio],
      %w[provision turf-monster --yes],
      %w[deploy mcritchie-studio origin/release --yes],
      %w[deploy turf-monster origin/release]
    ]

    guard(*lines).each do |result|
      assert_equal "returned", result["exit"],
                   "bin/qa-server #{result['argv'].join(' ')} is a REAL documented call — a guard that " \
                   "refuses it wedges the QA lane on every bin/release prepare"
    end
  end

  # A token that is not a subcommand stays the dispatcher's `else` to answer, as it
  # always did.
  test "a bare help flag falls through to the dispatchers own usage" do
    assert_equal "returned", one(%w[--help])["exit"]
  end

  # --- 2. the one real execution: the script itself is guarded ----------------

  # `list` is the only subcommand that cannot mutate — it reads the YAML registry
  # and prints it. Running it with `--help` proves the guard is IN THE SCRIPT'S PATH
  # rather than merely defined in it, which a static assertion cannot show.
  test "the real script answers list --help without listing anything" do
    out, err, status = Open3.capture3(bare_env, QA_SERVER.to_s, "list", "--help")

    assert_equal 1, status.exitstatus, "help exits 1 from the real script"
    assert_match(/bin\/qa-server list/, err)
    assert_empty out.strip, "nothing was listed"
  end

  # …and the guard does not break the read-only path it now sits in front of.
  test "the real script still runs its read-only subcommand" do
    out, _err, status = Open3.capture3(bare_env, QA_SERVER.to_s, "list")

    assert_predicate status, :success?, "bin/qa-server list must still work"
    assert_match(/mcritchie-studio/, out, "the registry is still listed")
  end

  # An unaccounted-for argument refuses from the real script too, before it acts.
  test "the real script refuses an unknown argument on its read-only subcommand" do
    out, err, status = Open3.capture3(bare_env, QA_SERVER.to_s, "list", "--force")

    assert_equal 2, status.exitstatus
    assert_match(/unrecognized argument/, err)
    assert_empty out.strip, "nothing was listed"
  end
end
