# frozen_string_literal: true

# Release::AcceptedCertification — the decision behind the promote's second guard.
# Standalone (no Rails, no DB, no fixtures):
#   ruby -Itest test/lib/release_accepted_certification_test.rb
#
# WHY THIS DRIVES SYNTHETIC YAML RATHER THAN THE REAL SIBLING CHECKOUTS. A test that
# reads turf-monster's actual ci.yml can only ever assert today's fleet, and it asserts
# it from a repo that does not own the file — so it goes red for a change made three
# repos away, skips entirely on the hub's CI runner (where no sibling is checked out),
# and passes blind exactly where it most needs to bite. The PROPERTY is what belongs
# under test: given a workflow, does this module correctly say whether `accepted` gets
# built? The live fleet question is asked at the moment it matters — inside
# promote_accepted_to_release!, against origin/accepted, by bin/release.rb — and pinned
# in test/lib/release_cli_accepted_gate_test.rb.
#
# EVERY POSITIVE CASE BELOW IS MUTATION-PAIRED: the same workflow with `accepted`
# removed must flip the verdict. A guard nobody has watched fail is not a guard.
require "minitest/autorun"
require_relative "../../app/models/release/accepted_certification"

class ReleaseAcceptedCertificationTest < Minitest::Test
  C = Release::AcceptedCertification

  # The hub's real shape: ~24 lines of comment between `on:` and `branches:`, which is
  # what defeated the grep that first tried to measure this.
  def hub_yaml(branches: "[ main, release, accepted ]")
    <<~YAML
      name: CI

      on:
        pull_request:
        # `release` is here for the same reason `main` is: it is a SHIPPABLE TIP.
        #
        # `accepted` IS THE SAME ARGUMENT ONE RUNG EARLIER, and it was the hole.
        push:
          branches: #{branches}

      jobs:
        test:
          runs-on: ubuntu-latest
    YAML
  end

  # ── the on: trap ────────────────────────────────────────────────────────────
  #
  # YAML 1.1 parses a bare `on:` as the BOOLEAN true. Reading doc["on"] reports every
  # workflow ever written as blind; this pins that the module reads the boolean key.
  def test_the_on_key_is_read_as_the_boolean_true_not_the_string
    doc = YAML.safe_load(hub_yaml)

    assert_nil doc["on"], "if this ever stops being nil, YAML changed and the module can be simplified"
    assert doc.key?(true), "the trigger block lives under the BOOLEAN true key"
    assert C.certifies?(hub_yaml), "the module must find the trigger block through the boolean key"
  end

  def test_a_comment_block_between_on_and_branches_does_not_hide_the_trigger
    assert_includes hub_yaml, "# `accepted` IS THE SAME ARGUMENT"
    assert C.certifies?(hub_yaml), "comments between `on:` and `branches:` are not the trigger list"
  end

  # ── the core property, mutation-paired ──────────────────────────────────────

  def test_a_workflow_listing_accepted_certifies_it
    assert C.certifies?(hub_yaml)
  end

  def test_MUTATION_removing_accepted_from_the_trigger_flips_the_verdict
    refute C.certifies?(hub_yaml(branches: "[ main, release ]")),
           "dropping `accepted` from the push trigger MUST read as blind — this is the whole guard"
  end

  def test_a_block_sequence_reads_the_same_as_a_flow_sequence
    block = hub_yaml(branches: "\n      - main\n      - release\n      - accepted")

    assert C.certifies?(block), "a block sequence is the same trigger list, spelled differently"
    refute C.certifies?(hub_yaml(branches: "\n      - main\n      - release"))
  end

  # ── the ways a trigger can exist and still certify nothing ──────────────────

  def test_a_pull_request_only_workflow_certifies_nothing
    refute C.certifies?("name: CI\non:\n  pull_request:\njobs: {}\n"),
           "pull_request only ever certifies a PR's own head, never the merged tree on accepted"
  end

  def test_a_bare_push_trigger_certifies_every_branch_including_accepted
    assert C.certifies?("name: CI\non:\n  push:\njobs: {}\n"),
           "`push:` with no branch filter builds EVERY branch — that repo is not blind"
  end

  # A path filter suppresses the RUN, not a job: a docs-only merge onto `accepted` gets
  # no verdict at all while the branch list still reads correct to a human auditor.
  def filtered_yaml(filter)
    "name: CI\non:\n  push:\n    branches: [main, release, accepted]\n    #{filter}\njobs: {}\n"
  end

  def test_a_path_filter_on_the_push_trigger_is_blind
    # The branch list still reads correct to a human auditor in BOTH of these.
    assert_includes filtered_yaml("paths: ['app/**']"), "accepted"

    refute C.certifies?(filtered_yaml("paths: ['app/**']")),
           "a paths filter can strand accepted with no run at all"
    refute C.certifies?(filtered_yaml("paths-ignore: ['docs/**']"))
    assert C.certifies?(filtered_yaml("tags: ['v*']")), "an unrelated push key is not a path filter"
  end

  def test_branches_ignore_certifies_unless_it_names_accepted
    assert C.certifies?("name: CI\non:\n  push:\n    branches-ignore: [wip]\njobs: {}\n")
    refute C.certifies?("name: CI\non:\n  push:\n    branches-ignore: [accepted]\njobs: {}\n")
  end

  def test_unparseable_or_empty_yaml_is_blind_never_a_silent_pass
    refute C.certifies?("")
    refute C.certifies?("\tthis: is not: valid yaml: at all\n")
    refute C.certifies?(nil)
  end

  # ── which workflow is the repo's suite, per the registry ────────────────────

  CONFIG = {
    "gems" => { "studio-engine" => {}, "solana-studio" => {} },
    "apps" => { "mcritchie-studio" => {}, "turf-monster" => {} }
  }.freeze

  def test_an_app_repos_suite_is_the_default_CI_workflow
    assert_equal "CI", C.workflow_for("turf-monster", CONFIG)
    assert_equal "CI", C.workflow_for("McRitchie-Studio/turf-monster", CONFIG), "owner-qualified names resolve too"
  end

  def test_the_engines_suite_is_Engine_CI_not_CI
    assert_equal "Engine CI", C.workflow_for("studio-engine", CONFIG)
  end

  def test_a_gem_declaring_no_suite_workflow_is_exempt_not_blind
    assert_nil C.workflow_for("solana-studio", CONFIG)
    assert C.certified?({}, C.workflow_for("solana-studio", CONFIG)),
           "solana-studio ships no .github/workflows at all — a declared exemption, not a gap"
  end

  # nil (declared) and unmapped (forgotten) must never collapse into one silent pass.
  def test_a_gem_MISSING_from_the_map_is_blind_not_silently_exempt
    config = { "gems" => { "brand-new-gem" => {} }, "apps" => {} }

    assert_equal C::UNMAPPED, C.workflow_for("brand-new-gem", config)
    refute C.certified?({ "ci.yml" => hub_yaml }, C.workflow_for("brand-new-gem", config)),
           "an unmapped gem is an oversight; exempting it rebuilds the silence this guard removes"
  end

  # ── the declared workflow is matched by NAME, across every file the repo ships ──

  def engine_yaml(name: "Engine CI", branches: "[main, release, accepted]")
    "name: #{name}\non:\n  pull_request:\n  push:\n    branches: #{branches}\njobs: {}\n"
  end

  def test_the_declared_workflow_is_found_by_name_not_by_filename
    files = { ".github/workflows/engine-ci.yml" => engine_yaml }

    assert C.certified?(files, "Engine CI"), "the file may be named anything; the `name:` is the identity"
  end

  # The reason consumer-ci.yml is out of scope, asserted rather than asserted-by-comment:
  # the verdict readers fold the DECLARED suite only, so another workflow certifying
  # `accepted` does not make the repo certified.
  def test_a_DIFFERENT_workflow_certifying_accepted_does_not_cover_the_declared_suite
    files = {
      ".github/workflows/engine-ci.yml"   => engine_yaml(branches: "[main, release]"),
      ".github/workflows/consumer-ci.yml" => engine_yaml(name: "Consumer CI")
    }

    refute C.certified?(files, "Engine CI"),
           "Consumer CI building accepted is irrelevant — Ci::BranchGate reads Engine CI"
  end

  def test_a_repo_shipping_no_workflow_file_for_its_declared_suite_is_blind
    refute C.certified?({}, "CI")
    refute C.certified?({ ".github/workflows/deploy.yml" => engine_yaml(name: "Deploy") }, "CI")
  end

  # ── the fleet answer ────────────────────────────────────────────────────────

  def test_blind_names_every_uncertified_repo_and_only_those
    sources = {
      "mcritchie-studio"     => { "ci.yml" => hub_yaml },
      "turf-monster"         => { "ci.yml" => hub_yaml(branches: "[ main, release ]") },
      "mcritchie-industries" => { "ci.yml" => hub_yaml(branches: "[ main, release ]") },
      "studio-engine"        => { "engine-ci.yml" => engine_yaml(branches: "[main, release]") },
      "solana-studio"        => {}
    }
    config = {
      "gems" => { "studio-engine" => {}, "solana-studio" => {} },
      "apps" => { "mcritchie-studio" => {}, "turf-monster" => {}, "mcritchie-industries" => {} }
    }

    assert_equal %w[turf-monster mcritchie-industries studio-engine], C.blind(sources, config),
                 "this is the fleet as measured on 2026-08-18, before the rollout"

    # …and the same fleet after it: every app lists accepted, the engine lists it in
    # Engine CI, and solana-studio stays exempt by declaration.
    fixed = sources.merge(
      "turf-monster"         => { "ci.yml" => hub_yaml },
      "mcritchie-industries" => { "ci.yml" => hub_yaml },
      "studio-engine"        => { "engine-ci.yml" => engine_yaml }
    )

    assert_empty C.blind(fixed, config)
  end

  def test_blind_over_an_empty_fleet_names_nothing_and_does_not_raise
    assert_empty C.blind({}, CONFIG)
  end
end
