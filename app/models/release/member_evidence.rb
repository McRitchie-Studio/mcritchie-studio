class Release
  # PER-REPO EVIDENCE for a release member: may this task be stamped `assembled`
  # (QA-green) or `shipped` (on `main`) given what the release run actually LANDED,
  # repo by repo?
  #
  # WHY IT EXISTS — the 2026-08-13 half-ship. `land-rails-security-patch` named two
  # repos (mcritchie-studio, turf-monster). The pipeline planned from the SINGULAR
  # Task#release_repo, so it promoted, QA'd and shipped the hub while turf was never
  # touched — and then stamped the task `assembled`, then `shipped`, then
  # `merged: "main"`. The board asserted a security patch reached production on a
  # repo whose `main` had not moved. Nothing would ever have revisited it.
  #
  # Task#release_repos closes the mechanism (every stage now plans over EVERY repo a
  # task names). This module is the SECOND line: even if a repo goes missing from the
  # plan again — a new field, a new caller, a hand-run promote — the member cannot be
  # STAMPED for a repo the release has no landed record of. A stamp is a durable
  # claim about production; it must be backed by evidence, not by the plan that was
  # supposed to produce it.
  #
  # Deliberately IO-free and Rails-free (like Release::SweepPlan / ShipSequence /
  # CleanCheck): it takes plain repo lists and returns a decision, so the rule lives
  # in ONE unit-tested place and both the record side and the CLI can consult it.
  # Callers supply the classification (which repos are gems) — the registry read is
  # theirs, not this module's.
  module MemberEvidence
    module_function

    # The repos a member NAMES that the release has NO landed record for.
    # `exempt` drops repos the evidence does not apply to — gems are published,
    # not deployed, so they carry no QA sha and no ff'd `main`; demanding one
    # would hold every gem member forever.
    def unproven(repos:, proven:, exempt: [])
      (list(repos) - list(exempt)) - list(proven)
    end

    # Must this member be HELD — left un-stamped — for lack of per-repo evidence?
    #
    # Two independent entitlements, either of which is enough:
    #   * the member names MORE THAN ONE repo. This is the incident shape, and the
    #     only shape in which a repo can vanish from a member's identity without
    #     anything else noticing. Evidence is mandatory, always, even against a
    #     release that recorded none.
    #   * the release RECORDED per-repo evidence and this member's repo is not in
    #     it. Once a run has shown what it landed, every member is held to that
    #     record, single-repo members included.
    #
    # A release with NO recorded evidence carrying only single-repo members is the
    # model-driven path (Release::Conductor.prepare! with no real deploy behind it):
    # it asserts nothing per repo, so it withholds nothing. That is the one gap, it
    # is stated rather than hidden, and it is not reachable from `bin/release` —
    # every real prepare records qa_shas, every real ship records shipped_shas.
    def hold?(repos:, proven:, exempt: [])
      return false if unproven(repos: repos, proven: proven, exempt: exempt).empty?

      list(proven).any? || list(repos).size > 1
    end

    # The sentence a held member gets on the release log / the raise. Names the
    # repos with no record and what the operator must do about it — a refusal that
    # doesn't say which repo is missing just moves the mystery.
    def hold_reason(slug:, repos:, proven:, exempt: [], stamp: "assembled")
      missing = unproven(repos: repos, proven: proven, exempt: exempt)
      "#{slug} names #{list(repos).size} repo(s) (#{list(repos).join(', ')}) but this release " \
        "landed nothing for #{missing.join(', ')} — refusing to stamp `#{stamp}`. " \
        "Promote and deploy #{missing.join(', ')} on this candidate (or drop it from the task's " \
        "devops.repositories if it carries no work), then re-run."
    end

    def list(values)
      Array(values).map { |value| value.to_s.strip }.reject(&:empty?).uniq
    end
  end
end
