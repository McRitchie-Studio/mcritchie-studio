# frozen_string_literal: true

module Ci
  # Is a BRANCH's CI concluded green? The DB-native answer for the one branch nothing
  # used to certify: `accepted`.
  #
  # THE HOLE THIS CLOSES. .github/workflows/ci.yml triggered on pull_request and on
  # pushes to main and release — never on accepted. A pull_request run only certifies
  # a PR's own head against the base as it was at that moment, so when review merged
  # several approved PRs, the resulting combination was a tree no CI run had ever
  # executed. That gap was discovered one rung too late, at the release push, after
  # the sweep had already promoted, where unwinding it means unwinding a release.
  # ci.yml's own comment made this argument for `release`; this applies it to the rung
  # below, where the offender can still be identified cheaply.
  #
  # WHY IT REUSES Ci::ReviewGate RATHER THAN RE-IMPLEMENTING. "Green" is a subtle fold
  # (one vote per workflow, fail-closed on anything short of `completed`, SHA-addressed
  # so a lane GitHub ran on the same tree is never dropped) and CiStatus owns it. The
  # SHA resolution is equally subtle — the newest ingested run of the repo's DECLARED
  # suite workflow, never "any run on the branch", because an unrelated downstream run
  # once authorised a merge on its own. Both are borrowed verbatim here, so a branch
  # verdict and a review verdict can never drift on what green means.
  #
  # DATA SOURCE is our own ingested GithubWorkflowRun rows, never a live gh call — and
  # every registered repo now delivers them, since the App-level webhook was wired on
  # 2026-08-14. Ci::Ingestion.unwired names any repo that stops.
  class BranchGate
    class << self
      # A verdict Hash: { state: :green/:red/:pending/:none/…, sha: }.
      #
      # :none is the honest answer for "nothing ingested for this branch yet", and it
      # is NOT green — a caller that treats an unknown branch as passing reintroduces
      # exactly the silence this class exists to end.
      def verdict(repo, branch)
        nwo = Ci::ReviewGate.nwo_for(repo)
        return { state: :none, sha: nil } if nwo.empty? || branch.to_s.strip.empty?

        # FAIL CLOSED on an unresolved workflow, mirroring the review gate: a repo with
        # no declared suite must read :none, never "match any workflow on the branch".
        workflow = GithubWorkflowRun.ci_workflow_for(repo)
        return { state: :none, sha: nil } if workflow.blank?

        Ci::ReviewGate.require_ci_status
        sha = Ci::ReviewGate.latest_ci_sha(nwo, branch.to_s, workflow)
        return { state: :none, sha: nil } if sha.blank?

        CiStatus.for_sha(nwo, sha, Ci::ReviewGate.check_runs_payload(nwo, sha)).merge(sha: sha)
      end

      def green?(repo, branch)
        verdict(repo, branch)[:state] == :green
      end

      # RED means "we have a concluded verdict and it is not green" — deliberately
      # narrower than "not green". A branch that is :pending or :none is not yet
      # certified, and refusing a release for that would wedge the lane every time a
      # sweep raced a run it could simply credit or wait for. Only an ASSERTED failure
      # blocks; the absence of a verdict is handled by the caller's own wait/credit
      # path, exactly as the pre-QA gate already does.
      def red?(repo, branch)
        %i[red conflicted].include?(verdict(repo, branch)[:state])
      end
    end
  end
end
