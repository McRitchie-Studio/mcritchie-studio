# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"

# bin/release's ARGUMENT GUARD — the fix for the worst instance of a defect class
# that has now cost this ecosystem five times.
#
# THE DEFECT. bin/release dispatches with `case ARGV.shift` and each subcommand
# hand-reads only the flags it knows, so an argument none of them recognise is not
# an error — it is nothing. The BARE form was safe by accident (`bin/release
# --help` shifts "--help", matches no `when`, prints usage). In SUBCOMMAND
# position the same flag vanished:
#
#     bin/release prepare --yes --help
#
# shifted "prepare", dispatched, and ran the REAL sweep — `accepted` promoted onto
# `release` in every repo, batch PRs merged, membership written to the PRODUCTION
# board, QA deployed, with ASSUME_YES set so nothing paused to ask. `ship` is
# worse still: it pushes `main` and publishes gems, and a RubyGems version can
# never be re-pushed. The operator had typed the universal safe probe.
#
# WHY THIS FILE NEVER RUNS A MUTATING SUBCOMMAND. The thing under test is a
# command that ships software when probed, so "run it and see" is the one
# experiment that must never be performed: if the guard has regressed, the probe
# IS the outage. So the verdict is proven two ways, neither of which can mutate:
#
#   1. THE REAL METHOD, DRIVEN DIRECTLY. A bare ruby subprocess requires
#      bin/release.rb — which does NOT dispatch when it is not $PROGRAM_NAME —
#      and calls `guard_argv!` with an injected exiter. That is the production
#      method reading the production dictionary (Release::Cli::COMMANDS), with
#      the `case` statement never reached. Subprocess rather than an in-process
#      require because require_relative'ing an autoloadable path poisons later
#      tests in the run (see release_reporting_standalone_load_test.rb).
#
#   2. ONE REAL EXECUTION, of the ONLY read-only subcommand. `bin/release status`
#      reads the board and writes nothing, and `--local` keeps even that read off
#      production. It is therefore the single command whose worst case — the
#      guard having regressed — is a local read, not a promote. That execution is
#      what proves the script itself is guarded, rather than merely owning a
#      guard method nothing calls.
#
#   ruby -Itest test/integration/release_argv_guard_test.rb
class ReleaseArgvGuardTest < ActionDispatch::IntegrationTest
  RELEASE_RB = Rails.root.join("bin", "release.rb")

  # bin/release.rb is plain Ruby with NO bundler — every probe below runs it the
  # way an operator's shell does. Inheriting the suite's RUBYOPT would re-enter
  # bundler in the child and bury the verdict under a page of redefinition
  # warnings; unsetting it also keeps the bare load path honestly under test.
  BARE = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze

  def bare_env = SessionEnv.neutralized(BARE)

  # The five flags bin/release consumes from ARGV at LOAD time, before the
  # dispatcher runs. They are deliberately absent from COMMANDS: by the time the
  # guard reads the line they are already gone.
  GLOBAL_FLAGS = %w[--dry-run --prod --local --yes --skip-test-gate].freeze

  # Drive the REAL `guard_argv!` for each command line, in a subprocess that
  # requires bin/release.rb without dispatching. Returns one result hash per line:
  #   exit — the code the guard exited with, or "returned" when it let the
  #          dispatcher proceed (a clean line, or a token that is not a subcommand)
  #   out/err — what the guard printed.
  def guard(*command_lines)
    script = <<~RUBY
      require "json"
      require "stringio"
      require #{RELEASE_RB.to_s.inspect}

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

  # --- 1. help, from any position, on every subcommand ----------------------

  test "[integration] REGRESSION: `prepare --yes --help` exits without promoting anything" do
    r = one(["prepare", "--help"]) # --yes is consumed at load; this is the line that promoted

    assert_equal 1, r["exit"], "the reported line must exit, not fall through to the promote"
    assert_equal "", r["out"], "help on this CLI goes to stderr — exit 0 means a clean ladder here"
    assert_includes r["err"], "bin/release prepare [--task SLUG ...]",
                    "…and it must answer with prepare's own usage, not a generic banner"
  end

  test "[integration] every subcommand answers --help and -h without acting" do
    commands = Release::Cli::COMMANDS.keys
    lines = commands.flat_map { |c| [[c, "--help"], [c, "-h"]] }

    guard(*lines).each do |r|
      assert_equal 1, r["exit"], "bin/release #{r['argv'].join(' ')} did not exit on a help flag"
      assert_equal "", r["out"]
      assert_includes r["err"], "usage: bin/release #{r['argv'].first}"
    end
  end

  # ANY position, on purpose: `--by carl --help` is the same request as `--help`,
  # and a guard that only inspected the first argument would hand the mutation to
  # the second spelling.
  test "[integration] help is honoured after other flags, not only in first position" do
    [["ship", "--by", "carl", "--help"],
     ["status", "--clean-only", "--help"],
     ["retro", "rel-x", "--worked", "w", "--help"],
     ["merge", "task-a", "task-b", "--help"]].each do |argv|
      r = one(argv)
      assert_equal 1, r["exit"], "#{argv.join(' ')} dropped a trailing help flag"
    end
  end

  # --- 2. an argument nothing accounts for REFUSES, it is never guessed at ---

  test "[integration] an unrecognized flag refuses and names what did NOT happen" do
    r = one(["prepare", "--bogus"])

    assert_equal 2, r["exit"]
    assert_includes r["err"], 'unrecognized argument "--bogus"'
    assert_includes r["err"], "NOTHING was promoted onto `release`",
                    "the refusal's only job is answering 'did it happen?'"
  end

  test "[integration] a stray positional refuses where bare tokens mean nothing" do
    [["prepare", "rel-oops"], ["status", "some-task"], ["archive", "x"], ["init", "x"]].each do |argv|
      r = one(argv)
      assert_equal 2, r["exit"], "#{argv.join(' ')} silently ignored a token instead of refusing"
    end
  end

  test "[integration] a value flag left with nothing to consume refuses" do
    # A trailing `--task` used to yield nil and be compacted away, so
    # `prepare --task` swept the WHOLE queue while reading as a targeted run.
    assert_equal 2, one(["prepare", "--task"])["exit"]
    assert_equal 2, one(["ship", "--by"])["exit"]
  end

  test "[integration] a single-dash typo refuses rather than being treated as a slug" do
    assert_equal 2, one(["merge", "-override"])["exit"]
  end

  # --- 3. no false refusals: every real invocation still passes -------------

  test "[integration] the documented invocations pass the guard untouched" do
    real = [
      ["init"],
      ["merge", "task-a", "task-b"],
      ["merge", "task-a", "--override"],
      ["prepare"],
      ["prepare", "--task", "t-a", "--task", "t-b", "--slug", "rel-2026-08-31-x"],
      ["prepare", "--expedite", "--task", "t-a"],
      ["prepare", "--slug=rel-2026-08-31-x"],
      ["eject", "task-a", "--feedback", "needs rework"],
      ["ship"],
      ["ship", "--by", "steffon"],
      ["ship", "--finalize-only", "rel-2026-08-31-x"],
      ["ship", "--reason", "CI false negative"], # with the global --skip-test-gate
      ["finalize", "rel-2026-08-31-x", "--by", "steffon"],
      ["status"],
      ["status", "--clean-only", "--task", "t-a"],
      ["archive"],
      ["retro"],
      ["retro", "rel-2026-08-31-x", "--worked", "a", "--friction", "b", "--followup", "c", "--file-tasks"]
    ]

    guard(*real).each do |r|
      assert_equal "returned", r["exit"],
                   "the guard REFUSED a real invocation: bin/release #{r['argv'].join(' ')}\n#{r['err']}"
      assert_equal "", r["err"]
    end
  end

  # A bare `--help`, or a typo'd subcommand, is not the guard's business: it falls
  # through to the dispatcher's own `else`, which prints usage and exits 1 — the
  # behaviour this CLI has always had, unchanged by the fix.
  test "[integration] a non-subcommand falls through to the dispatcher, as before" do
    guard(["--help"], ["-h"], ["prepar"], []).each do |r|
      assert_equal "returned", r["exit"]
      assert_equal "", r["err"]
    end
  end

  # --- 4. the dictionary cannot drift away from the parsers -----------------

  # THE FAILURE MODE THIS CATCHES. Add a flag to a subcommand, forget the
  # dictionary, and the guard REFUSES the flag you just shipped — a release lane
  # wedged by its own safety rail. Scanning the parser call sites means the
  # dictionary is checked against the code that reads the flags, not against
  # documentation.
  test "[integration] every flag bin/release actually reads is declared in COMMANDS" do
    code = File.read(RELEASE_RB).lines.reject { |l| l.lstrip.start_with?("#") }.join
    read = code.scan(/(?:take_flag|opt_values?)\((?:ARGV,\s*)?"(--[a-z-]+)"/).flatten.uniq
    declared = Release::Cli::COMMANDS.values.flat_map { |s| s[:bool] + s[:value] }.uniq

    undeclared = read - declared - GLOBAL_FLAGS

    assert_empty undeclared,
                 "bin/release reads #{undeclared.join(', ')} but no COMMANDS entry declares it — the " \
                 "guard would REFUSE a flag the CLI supports. Add it to the owning subcommand's entry."
  end

  test "[integration] COMMANDS declares no flag bin/release never reads" do
    code = File.read(RELEASE_RB).lines.reject { |l| l.lstrip.start_with?("#") }.join
    read = code.scan(/(?:take_flag|opt_values?)\((?:ARGV,\s*)?"(--[a-z-]+)"/).flatten.uniq
    declared = Release::Cli::COMMANDS.values.flat_map { |s| s[:bool] + s[:value] }.uniq

    assert_empty declared - read,
                 "COMMANDS declares #{(declared - read).join(', ')}, which nothing in bin/release reads — " \
                 "the guard would ACCEPT a flag that is then silently dropped, which is the defect it closes"
  end

  # --- 5. the one seam only a real execution can prove ----------------------

  # Everything above proves the guard's VERDICT. This proves the SCRIPT calls it:
  # a guard that is required, tested and never invoked is exactly the shape of an
  # inert fix.
  #
  # `status` is the only subcommand this test is permitted to execute — it reads
  # and writes nothing — and `--local` keeps even that read off the production
  # board. If the guard has regressed the worst case is a local read; on every
  # other subcommand it would be a promote, a prod deploy, or a gem publish.
  test "[integration] the SCRIPT guards before it dispatches — proven by execution" do
    out, err, status = Open3.capture3(bare_env, RbConfig.ruby, RELEASE_RB.to_s,
                                      "status", "--local", "--help")

    assert_equal 1, status.exitstatus, "a probed bin/release must exit 1, never 0 (0 asserts a clean ladder)"
    assert_equal "", out, "nothing ran: status prints its banner to stdout the moment it is entered"
    assert_includes err, "usage: bin/release status [--clean-only] [--task SLUG]"
    assert_no_match(/Release status/, out + err,
                    "the subcommand was ENTERED — the guard is not wired ahead of the dispatch")
  end

  # The positional tripwire: the guard call must sit ABOVE `case ARGV.shift`.
  # Every mutation this CLI can perform is reached through that dispatcher, so a
  # guard below it protects nothing.
  test "[integration] guard_argv! is called before the dispatcher, not after" do
    code = File.read(RELEASE_RB).lines.reject { |l| l.lstrip.start_with?("#") }.join
    guard_at = code.index(/^  guard_argv!$/)
    dispatch_at = code.index("case ARGV.shift")

    refute_nil guard_at, "the dispatch block no longer calls guard_argv!"
    refute_nil dispatch_at
    assert_operator guard_at, :<, dispatch_at,
                    "guard_argv! runs AFTER the dispatcher — it cannot protect a subcommand that " \
                    "has already been entered"
  end
end
