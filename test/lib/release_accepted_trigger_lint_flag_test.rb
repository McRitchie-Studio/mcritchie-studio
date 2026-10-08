# frozen_string_literal: true

# The per-repo `accepted_trigger_lint` flag in the release repo registry. Standalone:
#   ruby -Itest test/lib/release_accepted_trigger_lint_flag_test.rb
#
# A flagged repo holds the `accepted` trigger rule in its own CI, so bin/release
# skips refuse_blind_accepted! for it. An unflagged repo is still refused at promote.
# Each test drives promote_accepted_to_release! in a child with a synthetic registry,
# so no test reads a sibling checkout, mints a token, dispatches or pushes.
require "minitest/autorun"
require "open3"
require "yaml"
require_relative "../../app/models/release/accepted_certification"
require_relative "../../bin/lib/release_registry"

class ReleaseAcceptedTriggerLintFlagTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  BLIND_YAML = "name: CI\non:\n  pull_request:\n  push:\n    branches: [main, release]\njobs: {}\n"
  CERTIFYING = "name: CI\non:\n  pull_request:\n  push:\n    branches: [main, release, accepted]\njobs: {}\n"

  SYNTHETIC = {
    "gems" => {},
    "apps" => { "flagged-app" => { "accepted_trigger_lint" => true }, "plain-app" => { "ladder" => "three-rung" } }
  }.freeze

  # The repos whose lint was read on their own origin/accepted. A flag added to the
  # registry without that read fails here.
  LINTED = %w[chain-ops mcritchie-industries mcritchie-studio rolio solana-studio studio-engine turf-monster].freeze

  # Promotes `sources.keys` with every repo shipping the given workflow tree. The RED
  # guard is pinned green, so a refusal here is the trigger refusal's.
  def promote(sources, ignore_flag: false)
    stub = <<~RUBY
      RELEASE_REPOS.replace(#{SYNTHETIC.inspect})
      def repo_path(repo) = "/nonexistent/\#{repo}"
      def sh(*_a, **_k) = ["abc1234", true]
      def ci_verdict(_repo, _sha) = { state: :green }
      def accepted_workflow_sources(repo) = #{sources.inspect}[repo]
    RUBY
    if ignore_flag
      stub += <<~RUBY
        Release::AcceptedCertification.singleton_class.prepend(Module.new do
          def trigger_linted?(_repo, _config) = false
        end)
      RUBY
    end
    script = %(ARGV.replace(["--help"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             stub +
             %(begin; promote_accepted_to_release!(#{sources.keys.inspect}, label: "rel-t"); ) +
             %(puts "PROMOTED"; rescue SystemExit; puts "EXITED"; end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  def blind(*repos) = repos.to_h { |repo| [repo, { ".github/workflows/ci.yml" => BLIND_YAML }] }

  def test_a_flagged_repo_skips_the_refusal
    out = promote(blind("flagged-app"))

    refute_match(/cannot certify `accepted`/, out)
    assert_match(/held by the repo's own CI lint in flagged-app/, out, "the skip is announced, naming the repo")
    refute_match(/must be ABLE to certify/, out, "with every repo flagged the guard reads no workflow tree")
  end

  def test_an_unflagged_repo_is_still_refused_with_the_same_reason
    out = promote(blind("plain-app"))

    assert_match(/promote refused — plain-app \(suite workflow "CI"\) cannot certify `accepted`/, out)
    assert_match(/has no push trigger for `accepted` on origin\/accepted/, out)
    assert_match(/NOTHING was promoted, recorded or deployed/, out)
    refute_includes out, "PROMOTED"
  end

  def test_a_mixed_promote_refuses_only_the_unflagged_repo
    out = promote(blind("flagged-app", "plain-app"))

    assert_match(/promote refused — plain-app \(suite workflow "CI"\) cannot certify/, out)
    refute_match(/flagged-app \(suite workflow/, out)
    refute_includes out, "PROMOTED"
  end

  def test_an_unflagged_certifying_repo_passes_and_is_named_alone
    out = promote(blind("flagged-app").merge("plain-app" => { ".github/workflows/ci.yml" => CERTIFYING }))

    refute_match(/cannot certify/, out)
    assert_match(/`accepted` is built by the declared suite workflow in plain-app$/, out)
  end

  # THE CONTROL: with the flag check answering false, the same flagged promote refuses.
  def test_CONTROL_without_the_flag_check_the_flagged_repo_is_refused
    out = promote(blind("flagged-app"), ignore_flag: true)

    assert_match(/promote refused — flagged-app \(suite workflow "CI"\) cannot certify `accepted`/, out)
    refute_includes out, "PROMOTED"
  end

  def test_only_a_literal_true_on_the_repos_own_row_counts
    cert = Release::AcceptedCertification
    config = { "gems" => { "a-gem" => { "accepted_trigger_lint" => true } },
               "apps" => { "yes" => { "accepted_trigger_lint" => true }, "str" => { "accepted_trigger_lint" => "true" },
                           "no" => { "accepted_trigger_lint" => false }, "bare" => nil, "plain" => {} } }

    assert cert.trigger_linted?("yes", config)
    assert cert.trigger_linted?("a-gem", config)
    assert cert.trigger_linted?("McRitchie-Studio/yes", config), "an owner-qualified name resolves to its row"
    %w[str no bare plain unregistered].each { |repo| refute cert.trigger_linted?(repo, config), repo }
    refute cert.trigger_linted?("yes", {}), "an unreadable registry flags nothing"
    refute cert.trigger_linted?("yes", { "apps" => nil })
  end

  def test_the_registry_flags_exactly_the_repos_whose_lint_was_read
    # The path is cited by its constant: spelling it would widen its fast-check lane.
    config = YAML.load_file(ReleaseRegistry::REGISTRY_PATH)
    repos = %w[gems apps].flat_map { |kind| config.fetch(kind).keys }
    flagged = repos.select { |repo| Release::AcceptedCertification.trigger_linted?(repo, config) }

    assert_equal LINTED, flagged.sort
    assert_operator (repos - flagged).size, :>=, 1, "an unflagged repo remains, so the refusal still has work"
  end
end
