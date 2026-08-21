# frozen_string_literal: true

# bin/release.rb's `accepted` gate — the decision that refuses to promote a branch
# GitHub has already called broken. Standalone:
#   ruby -Itest test/lib/release_cli_accepted_gate_test.rb
#
# DELIBERATELY A NEW FILE, not an addition to test/lib/release_cli_test.rb. That file
# is 7056 lines and was touched by 26 of the last 200 merged PRs; everyone appends at
# the bottom, so everyone conflicts at the bottom. Putting new work in a new file is
# the same rule the dor-check plugin seam encodes, applied to tests.
#
# WHAT IS BEING PINNED: the asymmetry. `red_accepted_repos` must refuse on an ASSERTED
# failure and on nothing else. If it ever grows to mean "not green", every sweep that
# races a still-running CI aborts a release — which is a worse outage than the one this
# gate prevents, and it arrives far more often.
require "minitest/autorun"
require "tmpdir"
require "open3"

class ReleaseCliAcceptedGateTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  def decide(probe)
    call = "puts red_accepted_repos(#{probe.inspect}).keys.inspect"
    out, = Open3.capture2e(RbConfig.ruby, "-e",
                           %(ARGV.replace(["--help"]); begin; load #{BIN.inspect}; rescue SystemExit; end; #{call}))
    eval(out.lines.reverse.find { |l| l.strip.start_with?("[") }.to_s) # rubocop:disable Security/Eval
  end

  def probe(states)
    states.transform_values { |s| { state: s.to_sym } }
  end

  def test_an_asserted_failure_refuses_the_promote
    assert_equal ["turf-monster"], decide(probe("mcritchie-studio" => "green", "turf-monster" => "red"))
  end

  def test_a_conflicted_branch_also_refuses
    assert_equal ["mcritchie-studio"], decide(probe("mcritchie-studio" => "conflicted"))
  end

  # THE WEDGE GUARDS. Each of these states means "no verdict yet", and each would
  # abort a release on every race if it counted as a failure.
  def test_pending_none_and_unverified_do_not_refuse
    assert_empty decide(probe("mcritchie-studio" => "pending", "turf-monster" => "none",
                              "studio-engine" => "unverified"))
  end

  def test_green_does_not_refuse
    assert_empty decide(probe("mcritchie-studio" => "green", "turf-monster" => "green"))
  end

  # An unrecognised state must not invent a refusal: a future CiStatus state would
  # otherwise become a release outage until somebody taught this line about it.
  def test_an_unknown_state_does_not_refuse
    assert_empty decide(probe("mcritchie-studio" => "some_new_state_nobody_taught_it"))
  end

  # Shape tolerance — the probe crosses a heroku run/JSON boundary, so a missing or
  # empty payload must read as "nothing to refuse", never raise mid-sweep.
  def test_a_missing_or_empty_probe_is_not_a_refusal
    assert_empty decide({})
    assert_empty decide({ "accepted" => {} })
    assert_empty decide(nil)
  end

  def test_every_red_repo_is_named_not_just_the_first
    assert_equal %w[mcritchie-industries turf-monster],
                 decide(probe("mcritchie-studio" => "green", "turf-monster" => "red",
                              "mcritchie-industries" => "red")).sort
  end

  # ── the guard is on the FUNCTION, so every caller inherits it ───────────────
  #
  # THE DEFECT THIS REPLACES. The refusal was originally wired in front of ONE of
  # promote_accepted_to_release!'s two call sites. bin/release prepare takes the
  # OTHER one, so the first real sweep after it shipped promoted with the guard
  # never running — its step line simply never appeared in the log.
  #
  # These tests therefore drive the FUNCTION, not a call site. That is the property
  # worth pinning: a third caller added tomorrow is guarded by construction, and
  # there is no call site left for anyone to forget. Asserting "the guard sits at
  # line N" would pin today's structure and pass again the day someone re-introduces
  # an unguarded path.

  def promote(probe_states)
    stub = <<~RUBY
      def repo_path(repo) = "/nonexistent/\#{repo}"
      def sh(*_a, **_k) = ["abc1234", true]
      def ci_verdict(_repo, _sha) = #{probe_states.values.first.to_sym.inspect}.then { |st| { state: st } }
    RUBY
    script = %(ARGV.replace(["--help"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             stub +
             %(begin; promote_accepted_to_release!(["mcritchie-studio"], label: "rel-t"); ) +
             %(puts "PROMOTED"; rescue SystemExit => e; puts "REFUSED"; end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  def test_a_red_accepted_refuses_inside_the_promote_function
    out = promote("mcritchie-studio" => "red")

    assert_includes out, "REFUSED", "the function itself must refuse, so every caller inherits it"
    assert_match(/accepted. CI is RED/, out)
    refute_includes out, "PROMOTED"
  end

  def test_a_pending_accepted_does_not_refuse_the_promote_function
    out = promote("mcritchie-studio" => "pending")

    refute_match(/CI is RED/, out, "a race is not an asserted failure")
  end

  def test_a_green_accepted_passes_the_guard
    out = promote("mcritchie-studio" => "green")

    refute_match(/CI is RED/, out)
    assert_match(/carries no RED verdict/, out,
                 "the guard must announce that it ran and passed")
  end

  # ── the BLIND guard: was that RED verdict even POSSIBLE? ────────────────────
  #
  # refuse_red_accepted! above reads a verdict and refuses on an asserted failure. It
  # can only ever fire in a repo whose suite workflow BUILDS `accepted` — and on
  # 2026-08-18 three of the four swept repos had no such trigger, so the guard passed
  # over them without ever having been capable of failing, while its success line named
  # them as checked. These pin the companion guard that asks the missing question.
  #
  # Same discipline as above: they drive the FUNCTION, so a third caller added tomorrow
  # inherits both guards by construction.

  CERTIFYING = "name: CI\non:\n  pull_request:\n  push:\n    branches: [main, release, accepted]\njobs: {}\n"
  BLIND_YAML = "name: CI\non:\n  pull_request:\n  push:\n    branches: [main, release]\njobs: {}\n"

  # Drives promote_accepted_to_release! with the workflow tree each repo ships on
  # origin/accepted stubbed in. ci_verdict is pinned GREEN throughout, so anything
  # these tests refuse was refused by the BLIND guard and not the RED one.
  # `declared_ci_less:` stubs GemCiWorkflows so one repo reads as having DECLARED
  # that it ships no suite. Injected here rather than added to bin/release.rb —
  # the production code grows no test-only seam.
  def promote_with_workflows(sources, repos: sources.keys, declared_ci_less: nil)
    stub = <<~RUBY
      def repo_path(repo) = "/nonexistent/\#{repo}"
      def sh(*_a, **_k) = ["abc1234", true]
      def ci_verdict(_repo, _sha) = { state: :green }
      def accepted_workflow_sources(repo) = #{sources.inspect}[repo]
    RUBY
    if declared_ci_less
      # The guard resolves the name through Release::AcceptedCertification.blind →
      # .workflow_for, NOT GemCiWorkflows directly, so THAT is the seam to stub.
      # (Stubbing declared_ci_less? leaves workflow_for defaulting to "CI" for an
      # unregistered repo, and the guard then reports it blind — which is how this
      # harness told me I had picked the wrong lever.)
      stub += <<~RUBY
        Release::AcceptedCertification.singleton_class.prepend(Module.new do
          def workflow_for(repo, config)
            repo.to_s == #{declared_ci_less.inspect} ? nil : super
          end
        end)
      RUBY
    end
    script = %(ARGV.replace(["--help"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             stub +
             %(begin; promote_accepted_to_release!(#{repos.inspect}, label: "rel-t"); ) +
             %(puts "PROMOTED"; rescue SystemExit; puts "EXITED"; end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  def test_a_repo_whose_suite_never_builds_accepted_refuses_the_promote
    out = promote_with_workflows({ "turf-monster" => { ".github/workflows/ci.yml" => BLIND_YAML } })

    assert_match(/cannot certify `accepted`/, out)
    assert_match(/turf-monster \(suite workflow "CI"\)/, out, "the guard must NAME the repo, not just refuse")
    refute_includes out, "PROMOTED"
  end

  def test_a_certifying_repo_passes_the_blind_guard
    out = promote_with_workflows({ "turf-monster" => { ".github/workflows/ci.yml" => CERTIFYING } })

    refute_match(/cannot certify/, out)
    assert_match(/`accepted` is built by the declared suite workflow in turf-monster/, out,
                 "the guard must announce that it ran and passed, naming what it actually checked")
  end

  # THE MUTATION, end to end: the same fleet, one repo's trigger line edited.
  def test_MUTATION_dropping_accepted_from_one_repos_trigger_flips_the_promote
    fleet = { "mcritchie-studio" => { "ci.yml" => CERTIFYING }, "turf-monster" => { "ci.yml" => CERTIFYING } }

    assert_match(/is built by the declared suite workflow/, promote_with_workflows(fleet))

    mutated = fleet.merge("turf-monster" => { "ci.yml" => BLIND_YAML })
    out = promote_with_workflows(mutated)

    assert_match(/turf-monster \(suite workflow "CI"\)/, out)
    refute_match(/mcritchie-studio \(suite/, out, "only the offending repo is named")
  end

  # The engine's suite is `Engine CI`, so a `CI`-named workflow in that repo is NOT its
  # verdict — this is why consumer-ci.yml is out of scope, asserted rather than assumed.
  def test_the_engines_declared_suite_is_the_one_that_must_carry_accepted
    engine = "name: Engine CI\non:\n  push:\n    branches: [main, release]\njobs: {}\n"
    consumer = "name: Consumer CI\non:\n  push:\n    branches: [main, release, accepted]\njobs: {}\n"
    out = promote_with_workflows({ "studio-engine" => { "engine-ci.yml" => engine, "consumer-ci.yml" => consumer } })

    assert_match(/studio-engine \(suite workflow "Engine CI"\)/, out,
                 "Consumer CI building accepted is irrelevant — the verdict readers fold Engine CI")
  end

  # UNREADABLE IS NOT A FINDING. accepted_workflow_sources returns nil when the tree
  # could not be read; turning an I/O hiccup into a release outage is its own false alarm.
  def test_an_unreadable_repo_is_reported_but_does_not_refuse
    out = promote_with_workflows({ "turf-monster" => nil }, repos: ["turf-monster"])

    refute_match(/cannot certify/, out)
    assert_match(/could not read \.github\/workflows/, out, "silence about an unread repo is the bug, not the refusal")
  end

  # DELETING the suite workflow is the loudest form of this regression, and it must NOT
  # be confused with the unreadable case above. An empty workflow tree read from a REAL
  # checkout is a finding; only a path we could not read at all is excused.
  def test_a_repo_that_deleted_its_suite_workflow_is_blind
    out = promote_with_workflows({ "turf-monster" => {} })

    assert_match(/turf-monster \(suite workflow "CI"\)/, out,
                 "an app repo shipping no suite workflow cannot certify anything")
    refute_includes out, "PROMOTED"
  end

  # A repo that ships no .github/workflows at all and DECLARES that (nil in the
  # registry map) must not read as a gap. solana-studio was the live example until
  # 2026-08-20; no registered gem declares nil now, so the declaration is STUBBED
  # in the subprocess — the exemption still has to work for the next such gem.
  def test_a_repo_declaring_no_suite_workflow_is_exempt_not_blind
    out = promote_with_workflows({ "quiet-gem" => {} },
                                 declared_ci_less: "quiet-gem")

    refute_match(/cannot certify/, out)
  end

  # The other half, and the one that bites today: a gem that DOES declare a lane
  # certifies through it like any app. solana-studio's Gem CI lists `accepted` on
  # purpose — without that, this guard would refuse every promote carrying it.
  def test_a_gem_declaring_a_suite_certifies_through_it
    gem_ci = "name: Gem CI\non:\n  pull_request:\n  push:\n    branches: [accepted, release, main]\njobs: {}\n"
    out = promote_with_workflows({ "solana-studio" => { ".github/workflows/gem-ci.yml" => gem_ci } })

    refute_match(/cannot certify/, out)
    assert_match(/`accepted` is built by the declared suite workflow in solana-studio/, out,
                 "the guard must POSITIVELY certify it, not merely fail to refuse")
  end

  # …and the trap that shape invites: a declared lane that never builds `accepted`
  # is WORSE than none, because the RED guard passes over it without ever having
  # been capable of failing.
  def test_a_gem_whose_lane_skips_accepted_is_blind_not_exempt
    gem_ci = "name: Gem CI\non:\n  pull_request:\n  push:\n    branches: [main, release]\njobs: {}\n"
    out = promote_with_workflows({ "solana-studio" => { ".github/workflows/gem-ci.yml" => gem_ci } })

    assert_match(/solana-studio \(suite workflow "Gem CI"\) cannot certify `accepted`/, out)
    refute_includes out, "PROMOTED"
  end
end
