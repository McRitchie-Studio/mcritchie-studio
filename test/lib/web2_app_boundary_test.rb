# frozen_string_literal: true

# Guard test for the web2/web3 app-template boundary (lib/web2_app_boundary.rb).
#
# THE CONTRACT: an app that does not declare Studio.features :web3 must not
# declare a WEB3 ADD template gem. The rule was decided 2026-08-31
# (docs/agents/system/app-templates.md) and until now existed only as prose.
#
# WHAT THIS FILE ADDS OVER THE DOC. The doc can be true and the tree still
# drift; nothing re-reads a doc. Here the boundary is read from two signals that
# cannot be talked out of: the app's own runtime Studio.features, and Bundler's
# own parse of the Gemfile. Neither is a substring search, which matters in this
# repo more than usual — "solana" appears in comments (app/views/layouts/
# application.html.erb) and throughout the managed-app registry that names the
# solana-studio REPO (app/models/release/repos.rb, ci/app_ladder.rb,
# reviewer_selector.rb). Those are not Solana logic and a grep-based guard would
# flag every one of them.
#
# THE HUB IS THE ONE VIOLATION, AND IT IS EXEMPT ON PURPOSE. mcritchie-studio
# cannot satisfy this today: the admin signing console is its last real use of
# the gem and stays until the console moves to turf-monster. So the boundary
# lands enforced-with-one-named-exemption rather than waiting for that move. The
# exemption is not a mute — test_integration_hub_exemption_is_live below proves
# it still describes real code, and
# test_integration_hub_would_fail_without_its_exemption proves the check bites
# the REAL committed tree, not just fixtures.
#
# Run directly:
#   bin/rails test test/lib/web2_app_boundary_test.rb
#
# Two tiers (backend shape):
#   [unit]        the rule and the allowlist's three self-audits, over fixtures
#                 on a real temp filesystem.
#   [integration] the REAL committed Gemfile and the REAL booted Studio.features.
require "test_helper"
require "tmpdir"

class Web2AppBoundaryTest < ActiveSupport::TestCase
  # ── Fixtures ────────────────────────────────────────────────────────────
  # A well-formed exemption, used as the baseline the unit tests break one field
  # at a time. `justified_by` points at a file the test actually creates, so the
  # staleness check runs against a real filesystem rather than a stubbed one.
  def sound_entry(overrides = {})
    {
      gem: "solana-studio",
      reason: "a console that still uses it",
      justified_by: %w[app/services/signing],
      clearing_task: "move-signing-console",
      doc: "docs/app-templates.md",
      recorded_on: "2026-08-31",
    }.merge(overrides)
  end

  # Builds a throwaway repo root containing the given relative paths.
  def with_repo(paths)
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      Array(paths).each do |rel|
        target = root.join(rel)
        target.dirname.mkpath
        target.write("")
      end
      yield root
    end
  end

  def kinds(violations) = violations.map(&:kind).sort

  # ── [unit] the rule itself ──────────────────────────────────────────────

  test "unit web2 app declaring a web3 gem is a violation" do
    with_repo([]) do |root|
      found = Web2AppBoundary.violations(
        app: "rolio", features: [], dependencies: %w[rails solana-studio],
        repo_root: root, allowlist: {}
      )
      assert_equal [:undeclared_web3_gem], kinds(found)
      assert_equal "solana-studio", found.first.gem
    end
  end

  test "unit web2 app with no web3 gem is clean" do
    with_repo([]) do |root|
      found = Web2AppBoundary.violations(
        app: "rolio", features: [], dependencies: %w[rails pg puma],
        repo_root: root, allowlist: {}
      )
      assert_empty found
    end
  end

  test "unit web3 app declaring the gem is clean" do
    with_repo([]) do |root|
      found = Web2AppBoundary.violations(
        app: "turf-monster", features: %i[web3 leveling],
        dependencies: %w[rails solana-studio], repo_root: root, allowlist: {}
      )
      assert_empty found
    end
  end

  # The feature list arrives from config as symbols, but a string must not slip
  # the guard — an app is web3 by declaring it, however it spells it.
  test "unit web3 declared as a string still counts as web3" do
    with_repo([]) do |root|
      found = Web2AppBoundary.violations(
        app: "turf-monster", features: ["web3"],
        dependencies: %w[solana-studio], repo_root: root, allowlist: {}
      )
      assert_empty found
    end
  end

  # A web3 app is NOT a wildcard: :leveling is not :web3.
  test "unit an unrelated feature does not grant web3" do
    with_repo([]) do |root|
      found = Web2AppBoundary.violations(
        app: "rolio", features: %i[leveling age_gate],
        dependencies: %w[solana-studio], repo_root: root, allowlist: {}
      )
      assert_equal [:undeclared_web3_gem], kinds(found)
    end
  end

  # ── [unit] the allowlist's self-audits ──────────────────────────────────

  test "unit a sound exemption suppresses the violation" do
    with_repo(%w[app/services/signing docs/app-templates.md]) do |root|
      found = Web2AppBoundary.violations(
        app: "hub", features: [], dependencies: %w[solana-studio],
        repo_root: root, allowlist: { "hub" => sound_entry }
      )
      assert_empty found
    end
  end

  # THE ANTI-ROT MECHANISM. When the code that justified the exemption is gone,
  # the exemption expires by itself and says so — it cannot outlive its reason.
  test "unit exemption goes stale when its justification disappears" do
    with_repo(%w[docs/app-templates.md]) do |root|
      found = Web2AppBoundary.violations(
        app: "hub", features: [], dependencies: %w[solana-studio],
        repo_root: root, allowlist: { "hub" => sound_entry }
      )
      assert_equal [:stale_exemption], kinds(found)
    end
  end

  # Threshold: the gem cannot be removed while ANY consumer remains, so one
  # surviving path keeps the exemption live.
  test "unit exemption survives while any justification path remains" do
    entry = sound_entry(justified_by: %w[app/services/signing lib/tasks/signing.rake])
    with_repo(%w[lib/tasks/signing.rake docs/app-templates.md]) do |root|
      found = Web2AppBoundary.violations(
        app: "hub", features: [], dependencies: %w[solana-studio],
        repo_root: root, allowlist: { "hub" => entry }
      )
      assert_empty found
    end
  end

  test "unit exemption naming neither a task nor an unfiled reason is refused" do
    entry = sound_entry(clearing_task: nil)
    with_repo(%w[app/services/signing docs/app-templates.md]) do |root|
      found = Web2AppBoundary.violations(
        app: "hub", features: [], dependencies: %w[solana-studio],
        repo_root: root, allowlist: { "hub" => entry }
      )
      assert_equal [:nameless_exemption], kinds(found)
    end
  end

  # An honest "no task exists yet" is a legal exit — pointing at a slug that
  # resolves to nothing would be worse than saying so.
  test "unit an explicit unfiled reason satisfies the exit requirement" do
    entry = sound_entry(clearing_task: nil, unfiled_reason: "not filed; sequences after X")
    with_repo(%w[app/services/signing docs/app-templates.md]) do |root|
      found = Web2AppBoundary.violations(
        app: "hub", features: [], dependencies: %w[solana-studio],
        repo_root: root, allowlist: { "hub" => entry }
      )
      assert_empty found
    end
  end

  test "unit exemption with no justified_by paths can never expire and is refused" do
    entry = sound_entry(justified_by: [])
    with_repo(%w[docs/app-templates.md]) do |root|
      found = Web2AppBoundary.violations(
        app: "hub", features: [], dependencies: %w[solana-studio],
        repo_root: root, allowlist: { "hub" => entry }
      )
      assert_equal [:unjustified_exemption], kinds(found)
    end
  end

  test "unit exemption pointing at a missing doc is refused" do
    with_repo(%w[app/services/signing]) do |root|
      found = Web2AppBoundary.violations(
        app: "hub", features: [], dependencies: %w[solana-studio],
        repo_root: root, allowlist: { "hub" => sound_entry }
      )
      assert_equal [:missing_doc_pointer], kinds(found)
    end
  end

  # Once the gem is finally dropped, the leftover entry is itself flagged, so
  # the allowlist cannot accumulate dead entries.
  test "unit exemption for an app no longer carrying the gem is obsolete" do
    with_repo(%w[app/services/signing docs/app-templates.md]) do |root|
      found = Web2AppBoundary.violations(
        app: "hub", features: [], dependencies: %w[rails pg],
        repo_root: root, allowlist: { "hub" => sound_entry }
      )
      assert_equal [:obsolete_exemption], kinds(found)
    end
  end

  # ── [integration] the REAL committed tree ───────────────────────────────

  # The whole point: this repo, as committed, satisfies the boundary.
  test "integration this app satisfies the web2 boundary" do
    found = Web2AppBoundary.violations(
      app: "mcritchie-studio",
      features: Studio.features,
      dependencies: real_dependencies,
      repo_root: Rails.root
    )
    assert_empty found, found.map(&:message).join("\n")
  end

  # PROOF THE CHECK BITES THE REAL TREE, not merely the fixtures. Run the real
  # Gemfile and the real Studio.features against an EMPTY allowlist and the hub
  # fails — which is exactly the state the doc describes and the exemption
  # covers. If this ever goes quiet, either the gem left (delete the exemption
  # and this test) or the check stopped reading the Gemfile.
  test "integration hub would fail without its exemption" do
    found = Web2AppBoundary.violations(
      app: "mcritchie-studio",
      features: Studio.features,
      dependencies: real_dependencies,
      repo_root: Rails.root,
      allowlist: {}
    )
    assert_equal [:undeclared_web3_gem], kinds(found)
    assert_equal "solana-studio", found.first.gem
  end

  # The premise of the whole exemption, asserted rather than assumed: this app
  # really does declare itself web2.
  test "integration this app declares no web3 feature" do
    refute Web2AppBoundary.web3?(Studio.features),
           "mcritchie-studio declares Studio.features #{Studio.features.inspect}; the base " \
           "template says it ships no on-chain component"
  end

  # Bundler's parse, not a grep — the dependency really is declared.
  test "integration the real Gemfile declares the gem the exemption covers" do
    assert_includes real_dependencies, "solana-studio"
  end

  # The exemption is live: its justification still exists on disk, so it has not
  # silently outlived the console it was written for.
  test "integration hub exemption is live and well formed" do
    entry = Web2AppBoundary::ALLOWLIST.fetch("mcritchie-studio")
    found = Web2AppBoundary.exemption_violations(
      app: "mcritchie-studio", entry: entry,
      carried: %w[solana-studio], root: Rails.root
    )
    assert_empty found, found.map(&:message).join("\n")

    assert entry[:justified_by].any? { |path| Rails.root.join(path).exist? },
           "the signing console is gone — drop solana-studio and this ALLOWLIST entry"
  end

  # The acceptance criterion, enforced: every exemption says what clears it.
  test "integration every allowlist entry names what clears it" do
    Web2AppBoundary::ALLOWLIST.each do |app, entry|
      named = entry[:clearing_task].to_s.strip.presence ||
              entry[:unfiled_reason].to_s.strip.presence
      assert named, "#{app}'s exemption names neither a clearing task nor an unfiled reason"
    end
  end

  private

  # Structural read of the Gemfile — Bundler's own parse. A comment mentioning
  # solana cannot become a dependency here, and a dependency cannot hide from it.
  def real_dependencies
    Bundler.definition.dependencies.map(&:name)
  end
end
