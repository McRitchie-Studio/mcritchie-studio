# frozen_string_literal: true

require "yaml"

class Release
  # CAN THIS REPO'S CI EVER RENDER A VERDICT ON `accepted`?
  #
  # THE HOLE THIS CLOSES, and it is the quiet kind. `refuse_red_accepted!` reads each
  # promoted repo's `accepted` verdict and aborts on an asserted failure. That guard
  # works — but it can only ever fire in a repo whose suite workflow actually BUILDS
  # `accepted`. A repo with no such push trigger produces no runs, so the verdict is
  # absent, and an absent verdict does NOT refuse (deliberately — see
  # Ci::BranchGate#red?, where refusing on absence would wedge the lane on every race).
  #
  # So the guard PASSED for three of the four swept repos without ever having been
  # capable of failing, and its success line named them as if it had checked them.
  # Measured 2026-08-18:
  #
  #   mcritchie-studio      push branches [main, release, accepted]   certified
  #   turf-monster          push branches [main, release]             BLIND
  #   mcritchie-industries  push branches [main, release]             BLIND
  #   studio-engine         engine-ci.yml [main, release]             BLIND
  #
  # A guard that looks fleet-wide and covers a quarter is worse than no guard: it
  # manufactures confidence. This module is the missing half — it asks whether the
  # verdict was POSSIBLE, so "no red" can no longer mean "no eyes".
  #
  # WHY IT ASKS THE CONFIG AND NOT THE DATA. The sibling question — "has this repo
  # ever DELIVERED a run?" — is already answered by Ci::Ingestion.unwired, from
  # ingested rows. That read is the right shape for a repo that stops DELIVERING, but
  # it cannot see the failure mode here until after a push has already gone
  # uncertified, and it cannot distinguish "misconfigured" from "branch is quiet".
  # The trigger list is the CAUSE, it is deterministic, and it is readable offline —
  # so the rot is caught at the edit that causes it rather than at the release that
  # trips over it. The two guards are complements, not alternatives.
  #
  # Deliberately IO-FREE (no git, no network, no Rails), exactly like Release::Ladder:
  # `bin/release` require_relative's it for the promote guard, the Rails suite
  # autoloads it, and its unit test drives it with synthetic YAML. Callers do the
  # reading and hand the text in.
  module AcceptedCertification
    module_function

    # The rung this module exists for. `release` and `main` are guarded elsewhere
    # (each repo's own ci_workflow_triggers_test.rb); `accepted` is the one nothing
    # asked about fleet-wide.
    ACCEPTED = "accepted"

    # WHICH WORKFLOW CARRIES A REPO'S SUITE VERDICT — the SINGLE spelling in the
    # ecosystem. GithubWorkflowRun::CI_WORKFLOW / ::GEM_CI_WORKFLOWS now read from
    # here rather than declaring their own copy, because a second literal is exactly
    # how the gate went blind to studio-engine the first time: the gate hard-coded
    # "CI", every Engine CI run failed to match, and every studio-engine PR resolved
    # to :none. The map lives HERE and not in the model because bin/release is a
    # standalone script with no ActiveRecord — it cannot reference a model constant,
    # and a CLI-side copy would be that second literal all over again.
    DEFAULT_SUITE_WORKFLOW = "CI"
    GEM_SUITE_WORKFLOWS = {
      "studio-engine" => "Engine CI",
      "solana-studio" => nil # ships no suite workflow — declared, not overlooked
    }.freeze

    # A push trigger carrying a path filter is a SECOND, quieter way to go blind: the
    # filter suppresses the workflow RUN, so there are no jobs to skip and no checks
    # to go red — a docs-only merge onto `accepted` simply gets no verdict, while
    # `branches: [main, release, accepted]` still reads correct to anyone auditing it.
    PATH_FILTER_KEYS = %w[paths paths-ignore].freeze

    # Returned for a GEM that is registered but absent from GEM_SUITE_WORKFLOWS.
    # Distinct from nil ON PURPOSE: nil is an explicit "this repo ships no suite"
    # declaration (solana-studio), whereas an unmapped gem is an oversight, and the
    # two must not collapse into the same silent exemption.
    UNMAPPED = :unmapped

    # The workflow name whose runs carry `repo`'s suite verdict, given the parsed
    # registry. Mirrors GithubWorkflowRun.ci_workflow_for, minus the Rails.
    def workflow_for(repo, config)
      slug = repo.to_s.split("/").last.to_s
      return DEFAULT_SUITE_WORKFLOW unless config.fetch("gems", {}).key?(slug)

      GEM_SUITE_WORKFLOWS.fetch(slug, UNMAPPED)
    end

    # The repos among `sources` that CANNOT certify `branch`.
    #
    # `sources` is { repo => { workflow_path => yaml_text } } — every workflow file
    # the repo ships on the branch being promoted. Whole-repo, not one guessed
    # filename: the declared workflow is matched by its `name:` (the same key the
    # ingested runs carry), so renaming a file cannot blind this, and a repo that
    # certifies `accepted` in some OTHER workflow does not count — the verdict
    # readers only ever fold the declared suite.
    def blind(sources, config, branch: ACCEPTED)
      sources.to_h.reject { |repo, files| certified?(files, workflow_for(repo, config), branch) }.keys
    end

    # Does any workflow file declaring `workflow_name` certify pushes to `branch`?
    def certified?(files, workflow_name, branch = ACCEPTED)
      return true if workflow_name.nil? # declares it ships no suite workflow at all
      return false if workflow_name == UNMAPPED

      files.to_h.any? do |_path, text|
        name_of(text) == workflow_name && certifies?(text, branch)
      end
    end

    # The workflow's declared `name:`, or nil when the document is not a workflow.
    def name_of(yaml_text)
      doc = parse(yaml_text)
      doc.is_a?(Hash) ? doc["name"]&.to_s : nil
    end

    # Does this workflow build every push to `branch`?
    #
    # THE `on:` TRAP, and it is not hypothetical — it is why the sloppy grep that
    # first measured this file got the hub wrong. YAML 1.1 parses a bare `on:` key as
    # the BOOLEAN `true`, so `doc["on"]` is nil in every GitHub workflow ever written.
    # Reading the string key alone reports EVERY repo as blind; reading it with a
    # regex instead trips over the ~24 lines of comment that sit between `on:` and
    # `branches:` in the hub's own ci.yml.
    def certifies?(yaml_text, branch = ACCEPTED)
      doc = parse(yaml_text)
      return false unless doc.is_a?(Hash)

      on = doc[true] || doc["on"]
      # THE ARRAY/STRING FORMS BUILD EVERY BRANCH. `on: [push, pull_request]` and
      # `on: push` are both legal GitHub spellings for "push, unfiltered" — so they
      # certify this rung and every other. Reading only the mapping form would report
      # such a repo BLIND and refuse its promote, which is a false alarm that wedges
      # the release lane: precisely the failure mode refuse_red_accepted! tolerates
      # :none to avoid. No repo here uses these spellings today; a newly onboarded one
      # might, and it must not be greeted by a bogus refusal.
      return Array(on).map(&:to_s).include?("push") if on.is_a?(Array) || on.is_a?(String)

      return false unless on.is_a?(Hash) && on.key?("push")

      push = on["push"]
      return true if push.nil? # `push:` with no filter builds EVERY branch

      return false unless push.is_a?(Hash)
      return false if (push.keys & PATH_FILTER_KEYS).any?

      branches = push["branches"]
      # No `branches:` means every branch, minus anything `branches-ignore` excludes.
      return !Array(push["branches-ignore"]).map(&:to_s).include?(branch.to_s) if branches.nil?

      Array(branches).map(&:to_s).include?(branch.to_s)
    end

    # EXACT match, never glob expansion. `branches: ["**"]` genuinely does certify
    # `accepted`, and this reports it as blind — a FALSE POSITIVE, chosen knowingly.
    # The house style is an explicit rung list everywhere, so the case is theoretical;
    # and if it ever lands, the guard fails LOUDLY at a promote with the repo named,
    # which someone fixes in a minute. The opposite error — accepting a pattern that
    # does not actually match — restores the exact silence this module exists to end.
    def parse(yaml_text)
      YAML.safe_load(yaml_text.to_s, aliases: true)
    rescue StandardError
      nil
    end
  end
end
