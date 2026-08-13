require "test_helper"
require "open3"

# [integration] The Release reporting modules must load with NO RAILS.
#
# bin/release.rb is a plain Ruby script: it `require_relative`s these files
# directly and never boots the app. So a Rails-only construct added to any of them
# (ActiveSupport's `present?`, `blank?`, `Hash#except`, an autoloaded constant)
# does not fail a unit test — the unit tests run INSIDE Rails, where those exist.
# It fails at LOAD, in production, for EVERY bin/release command: prepare, ship,
# status, merge. The conductor would be dead before it printed a word.
#
# This tier is the only place that contract can be observed, so it runs the real
# load path in a SUBPROCESS with no Rails and no bundler, then exercises the
# composed reporting end to end.
#
# The subprocess also keeps this test honest about a known trap
# (test/lib/session_env_test.rb): `require_relative`ing an autoloadable path from
# INSIDE a Rails test process shadows the real Release AR model and poisons every
# later test in the run. Spawning a child asserts the bare load path without ever
# defining those constants here.
class ReleaseReportingStandaloneLoadTest < ActiveSupport::TestCase
  # The files bin/release.rb require_relative's for its failure/version reporting.
  MODULES = %w[
    app/models/release/gh_failure
    app/models/release/clean_check
    app/models/release/gem_version
  ].freeze

  # A bare child: no bundler, no RUBYOPT preload, no Rails.
  BARE_ENV = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze

  def run_bare(body)
    requires = MODULES.map { |m| %(require #{Rails.root.join("#{m}.rb").to_s.inspect}) }.join("\n")
    out, status = Open3.capture2e(BARE_ENV, RbConfig.ruby, "-e", "#{requires}\n#{body}")
    [out, status]
  end

  test "[integration] the reporting modules load with no Rails and no bundler" do
    out, status = run_bare(<<~RUBY)
      abort("Rails leaked into the child — this proves nothing") if defined?(Rails)
      print "loaded:#{'#{Release::GhFailure.name}'},#{'#{Release::CleanCheck.name}'},#{'#{Release::GemVersion.name}'}"
    RUBY

    assert status.success?, "bin/release's load path is broken — it would die before printing a word:\n#{out}"
    assert_includes out, "loaded:Release::GhFailure,Release::CleanCheck,Release::GemVersion"
  end

  # The whole point of the change, exercised through the real load path: a
  # credential failure quotes gh and advises re-minting, not a hand-run retry.
  test "[integration] a credential failure reports gh's words and the re-mint remedy" do
    out, status = run_bare(<<~RUBY)
      msg = Release::GhFailure.abort_message(
        headline: "could not open the batch PR in mcritchie-studio.",
        output: "pull request create failed: GraphQL: Resource not accessible by personal access token (createPullRequest)",
        fallback: "Open it by hand (`gh pr create --base release --head accepted`), then re-run."
      )
      print msg
    RUBY

    assert status.success?, out
    assert_includes out, "Resource not accessible by personal access token",
                    "gh's own sentence must reach the operator"
    assert_includes out, "bin/gh-app-git-credential", "and the remedy that actually works"
    refute_includes out, "Open it by hand", "the remedy that would have failed identically"
  end

  # The ladder verdict, through the same bare path: the board signal is named and
  # no tree relation is invented.
  test "[integration] the ladder verdict names the board signal, not a tree relation" do
    out, status = run_bare(<<~RUBY)
      v = Release::CleanCheck.evaluate(
        pending_tasks: [{ "slug" => "a" }, { "slug" => "b" }, { "slug" => "c" }],
        repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }]
      )
      print v["message"]
    RUBY

    assert status.success?, out
    headline = out.lines.first
    assert_includes headline, "3 task(s) still recorded as riding `release`"
    refute_includes headline, "release ≠ main", "git said the trees are identical"
    assert_includes out, "INTERRUPTED SHIP", "and the disagreement is explained"
  end

  test "[integration] the gem member line names the published version, not the local one" do
    out, status = run_bare(<<~RUBY)
      print Release::GemVersion.reported_version({ "studio-engine" => "0.41.0" }, "studio-engine", "0.40.0")
    RUBY

    assert status.success?, out
    assert_equal "0.41.0", out
  end

  # A PARTIAL git read must not become a confident claim about production. This
  # runs through the bare path because that is where the operator meets it: the
  # sentence is printed by bin/release, which has no Rails, and the completeness
  # rule uses Array/Hash operations that would be tempting to write with `blank?`.
  test "[integration] a partial release read prints no interrupted-ship claim" do
    out, status = run_bare(<<~RUBY)
      v = Release::CleanCheck.evaluate(
        pending_tasks: [{ "slug" => "a" }],
        repo_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
        unreadable_repos: [{ "repo" => "turf-monster", "rung" => "release" }]
      )
      print v["message"]
    RUBY

    assert status.success?, out
    refute_includes out, "ALREADY BE IN PRODUCTION",
                    "turf-monster's release rung was never read — the claim is unearned"
    refute_includes out, "the trees are identical"
    assert_includes out, "could NOT be read", "the real finding still reaches the operator"
  end

  # The remedies, composed through the real load path. Each names a DIFFERENT fix,
  # and the middle one contradicts the default on purpose.
  test "[integration] each credential shape gets its own remedy, bare-loaded" do
    out, status = run_bare(<<~RUBY)
      shapes = {
        "unset"     => "GraphQL: Resource not accessible by personal access token (createPullRequest)",
        "scope"     => "GraphQL: Resource not accessible by integration (createPullRequest)",
        "masked404" => "GraphQL: Could not resolve to a Repository with the name 'x/y'. (repository)"
      }
      shapes.each do |label, text|
        print "===\#{label}===\\n" + Release::GhFailure.abort_message(
          headline: "boom", output: text, fallback: "Open it by hand."
        ) + "\\n"
      end
    RUBY

    assert status.success?, out
    # The remedies are MULTI-LINE, so the sections are split on their markers
    # rather than read a line at a time.
    sections = out.split(/^===(\w+)===\n/).drop(1).each_slice(2).to_h
    assert_equal %w[unset scope masked404], sections.keys

    # Three shapes, three DIFFERENT remedies — one shared remedy collapses them.
    assert_includes sections["unset"], "Re-mint the GitHub App installation token"
    assert_includes sections["scope"], "unset GH_APP_ITEM"
    assert_includes sections["masked404"], "gh repo view"
    refute_includes sections["unset"], "unset GH_APP_ITEM",
                    "the identity remedy must not leak onto the shape a re-mint DOES fix"
    refute_includes sections["scope"], "Open it by hand", "all three still classify as credential"
  end

  # The absolute helper path is computed from __dir__, which is the construct most
  # likely to differ between a Rails-loaded and a bare-loaded file. Assert it
  # resolves the same either way, and to a file that exists.
  test "[integration] the re-mint remedy names an absolute helper that exists" do
    out, status = run_bare(<<~RUBY)
      print Release::GhFailure::GH_CREDENTIAL_HELPER
    RUBY

    assert status.success?, out
    assert_equal Release::GhFailure::GH_CREDENTIAL_HELPER, out,
                 "the bare load must resolve the same helper path as the Rails load"
    assert out.start_with?("/"), "a relative remedy depends on the cwd bin/release was launched from"
    assert File.executable?(out), "the remedy names #{out}, which is not an executable file"
  end

  # The recovery text, through the bare path — bin/release prints this one from a
  # branch that only runs on an interrupted prior run.
  test "[integration] the interrupted-run recovery quotes gh, bare-loaded" do
    out, status = run_bare(<<~RUBY)
      print Release::GhFailure.recovery_message(
        headline: "  ↷ https://example/811 already merged (interrupted prior run)",
        output: "failed to merge: Pull request #811 is already merged"
      )
    RUBY

    assert status.success?, out
    assert_includes out, "gh said:"
    assert_includes out, "Pull request #811 is already merged"
  end
end
