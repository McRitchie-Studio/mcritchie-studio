# frozen_string_literal: true

# WHICH WORKFLOW CARRIES A GEM REPO'S OWN SUITE VERDICT — the one place that is
# decided, readable from BOTH sides of the house.
#
# It lived as GithubWorkflowRun::GEM_CI_WORKFLOWS, which Rails autoloads and
# bin/release.rb — a standalone CLI that reads config/release_repos.yml directly
# and never boots Rails — cannot see. The gem publish gate needs exactly this
# answer before an irreversible push, so the map moved here: Rails autoloads
# lib/, and a CLI can require_relative it. Same reason lib/cert_evidence.rb sits
# here rather than under bin/lib.
#
# GithubWorkflowRun::GEM_CI_WORKFLOWS now POINTS AT THIS, so there is still one
# list. Adding a second literal anywhere would leave the next gem blind, which is
# the bug that made every studio-engine PR unclaimable by pr-review.
#
# A nil value is an EXPLICIT DECLARATION that the gem ships no suite workflow,
# not an oversight. That distinction is load-bearing in two different places:
#   · a reader cannot otherwise tell "unmapped by mistake" from "genuinely has no
#     suite", so Ci::ReviewGate treats an unresolved workflow as NOT-GREEN rather
#     than guessing;
#   · the publish gate must SKIP a declared-nil gem rather than wait for a run
#     that can never exist — before that distinction it polled the full window
#     and then told the operator to go and watch a run nobody will ever create.
module GemCiWorkflows
  MAP = {
    "studio-engine" => "Engine CI",
    # Was nil ("ships no suite workflow — declared, not overlooked") until
    # 2026-08-20, which was the right call while the gem was pure-Ruby Borsh
    # encoders every consumer suite exercised. It stopped being right when the
    # gem started shipping a Rails engine — an ERB partial and a browser guard
    # that a consumer RENDERS — because neither a packaging error nor a
    # JavaScript regression is visible to any consumer suite before publish.
    "solana-studio" => "Gem CI"
  }.freeze

  module_function

  # True when the registry DECLARES this gem has no suite workflow. Distinct from
  # "unmapped": an unknown repo returns false here, because absence of a
  # declaration is not a declaration of absence — an unmapped gem is BLIND and
  # must not be quietly exempted from a gate.
  def declared_ci_less?(repo)
    key = repo.to_s.split("/").last
    MAP.key?(key) && MAP[key].nil?
  end

  def mapped?(repo)
    MAP.key?(repo.to_s.split("/").last)
  end

  def workflow_for(repo)
    MAP[repo.to_s.split("/").last]
  end
end
