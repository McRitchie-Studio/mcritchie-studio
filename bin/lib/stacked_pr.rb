# frozen_string_literal: true

require_relative "fast_lane"

# IS THIS PR'S BASE A DELIBERATE STACK, OR A MISTAKE? (/tasks/review-guards-stacked-prs)
#
# Feature PRs target `accepted`. A PR whose base is something else is USUALLY mis-based and
# self-heals by retargeting — but not always: a base that is ANOTHER OPEN PR'S HEAD is a
# stack somebody built on purpose, and retargeting it changes what the PR MERGES without
# changing its head. `--match-head-commit` cannot see that, because the head is exactly what
# does not move.
#
# MEASURED 2026-09-13 on turf #701, stacked on turf #624 while #624 was HELD for a credential
# rotation: bin/ship retargeted it and the ship stranded (three false refusals from one
# action), and bin/pr-review would have retargeted AND MERGED it — dragging the held change
# onto `accepted` ahead of the rotation, which is the exact outcome the stack existed to
# prevent.
#
# ONE QUESTION, TWO POLICIES. bin/ship (the builder half) and bin/pr-review (the reviewer
# half) ask the same question — #assess — and must not answer IT differently; the reviewer
# half was filed precisely because the two had drifted for a release. What each caller DOES
# with the answer is policy, and policy is allowed to differ where the COST does:
#
#   ship, via #assess        doubt ⇒ REPAIR. A wrong retarget is loud and recoverable
#                            (`gh pr edit <n> --base <parent>`) and ship never merges.
#   review, via #guard_base  doubt ⇒ REFUSE. The retarget is followed one line later by a
#                            MERGE, so a wrong guess puts the parent's unmerged work on
#                            `accepted`, which `bin/release prepare` promotes to QA and prod.
#
# DO NOT "RESTORE" THE SYMMETRY. An earlier version of this header said guard_base PROCEEDS on
# an empty base and that :unreadable "falls to the repair in both" — true until
# /tasks/review-refuses-unread-base, and it survived that change as an instruction to undo it.
# Both are now REFUSALS on the review side; see #guard_base for the full list of five.
#
# AN EMPTY BASE IS NOT AN ANSWER, in either caller. `gh pr list --head "" --state open` is NO
# FILTER to real gh and returns EVERY open PR, so an unread or absent base would otherwise
# name the first open PR as the parent and preserve a mis-based PR on a coincidence. :no_base
# therefore never reaches gh; ship repairs it, review refuses it.
module StackedPr
  module_function

  # `reader` runs the gh read for the caller, because the two callers reach gh differently
  # (one is repo-scoped by cwd, the other by an explicit --repo). It returns [json, ok].
  #
  # => { state: :stacked, parent: {"number"=>…, "url"=>…} }
  #  | { state: :not_stacked } | { state: :unreadable } | { state: :no_base }
  def assess(base, &reader)
    branch = base.to_s.strip
    return { state: :no_base } if branch.empty?

    json, ok = reader.call(branch)
    return { state: :unreadable } unless ok

    parent = FastLane.open_pr(json)
    parent ? { state: :stacked, parent: parent } : { state: :not_stacked }
  end

  # Everything that is not a proven stack gets repaired — a merged parent (GitHub already
  # retargeted its children), a closed-unmerged one, a deleted branch, `release`, `main`.
  def repair?(assessment) = assessment[:state] != :stacked

  # One sentence per state, so a caller never prints a blank reason.
  def why(assessment)
    case assessment[:state]
    when :no_base     then "its base came back empty, which is no answer"
    when :unreadable  then "could not read whether an open PR has that head"
    when :not_stacked then "no OPEN PR has that head"
    else                   "open PR ##{assessment.dig(:parent, 'number')} has that head"
    end
  end
  # THE WHOLE BASE DECISION, EXECUTED HERE RATHER THAN READ FROM A SCRIPT.
  #
  # bin/pr-review has no execution harness — every test of it reads its SOURCE — and a source
  # test cannot see a branch that has been disabled. MEASURED twice: a mutant replacing the
  # refusal's condition with a literal false left the source assertions GREEN, and so did
  # wrapping the caller's whole block as `if false && base_ok`. So every decision lives here,
  # where a test drives it with spies and can assert what was NOT called.
  #
  # AT A MERGE, ANYTHING UNPROVEN REFUSES (/tasks/review-refuses-unread-base). This is REVIEW's
  # caller, and its answers deliberately INVERT the ones bin/ship gets from #assess:
  #
  #   ship (calls #assess)     doubt ⇒ REPAIR. A wrongly-retargeted stack is loud and
  #                            recoverable (`gh pr edit <n> --base <parent>`), and ship never
  #                            merges, so guessing wrong costs a retarget.
  #   review (calls this)      doubt ⇒ REFUSE. The retarget is followed one line later by a
  #                            MERGE, so guessing wrong costs the PARENT's unmerged work on
  #                            `accepted`, which `bin/release prepare` then promotes to QA and
  #                            production. The cost asymmetry inverts at the merge.
  #
  # Both still ask ONE question (#assess) — that is what keeps the halves from drifting. What
  # each does with the answer is policy, and policy is allowed to differ where the cost does.
  # This contradicts ms#1391's bullet "Empty or unread base falls to the repair path"; that
  # bullet was written for ship's arm and remains correct there.
  #
  # FOUR THINGS MUST BE PROVEN before a merge continues, and each one refuses on its own:
  #   1. the base READ succeeded              — otherwise there is no base to judge;
  #   2. the probe is aimed at the RIGHT repo — an unscoped `gh pr list` runs against the cwd
  #      repo and answers :not_stacked with ok=true, a false NEGATIVE that never surfaces;
  #   3. the base is not empty                — `gh pr list --head ""` is NO FILTER to gh;
  #   4. the base is not another OPEN PR's head.
  #
  # `list`, `edit` and `say` are the caller's own gh reader, gh writer, and printer.
  # => :proceed | :refused | :retargeted | :retarget_failed
  # THE TWO DEFAULTS ARE ASYMMETRIC ON PURPOSE. `base_read_ok:` defaults TRUE and
  # `repo_scope:` defaults NIL (which refuses), and that is not an oversight: a caller that
  # omits base_read_ok is one that read the base and has nothing to report, while a caller
  # that omits repo_scope has told us nothing about WHICH repo to probe — and probing the
  # wrong one answers :not_stacked with ok=true, a false NEGATIVE that never surfaces. The
  # permissive default is the harmless one; the closed default guards the silent failure.
  def guard_base(base:, accepted:, slug:, pr_url:, list:, edit:, say:, base_read_ok: true, repo_scope: nil)
    branch = base.to_s.strip

    unless base_read_ok
      refuse(say, slug, "its PR base could not be READ, so there is nothing to judge it against",
             remedy: "check `gh pr view #{pr_url} --json baseRefName` and re-review once it answers")
      return :refused
    end

    return :proceed if branch == accepted

    if branch.empty?
      refuse(say, slug, "its PR base came back EMPTY, which is no answer — and an empty --head is " \
                        "NO FILTER to gh, so probing it would name the first open PR by coincidence",
             remedy: "read the PR's base on GitHub and re-review; an open PR always has one")
      return :refused
    end

    if repo_scope.to_s.strip.empty?
      refuse(say, slug, "the repo to probe could not be derived from #{pr_url}, and an unscoped " \
                        "`gh pr list` asks the CWD repo — which answers a different question",
             remedy: "check devops.pr_url is a full https://github.com/<owner>/<repo>/pull/<n> URL")
      return :refused
    end

    stack = assess(branch) { |head| list.call(head) }

    if stack[:state] == :unreadable
      # NAME THE CALL THAT ACTUALLY DIED. The base read SUCCEEDED here — it returned #{branch}.
      # What failed is the PROBE that asks whether any open PR heads that branch, and saying
      # "the base could not be read" would send the reader to the wrong gh call.
      refuse(say, slug, "it could not be determined whether #{branch} is another open PR's head " \
                        "(#{why(stack)}) — the base read fine; the PROBE did not. An unproven base " \
                        "is not a mis-base, and the next step here is a MERGE",
             remedy: "re-run the review once gh answers; if #{branch} is a live PR's branch this is " \
                     "a STACK and that PR merges first")
      return :refused
    end

    if stack[:state] == :stacked
      parent = stack[:parent]
      refuse(say, slug, "its PR is based on #{branch}, which is open PR ##{parent["number"]} " \
                        "(#{parent["url"]}) — a deliberate STACK, not a mis-based PR",
             remedy: "re-review once ##{parent["number"]} lands; GitHub retargets this PR itself then")
      say.call("  Retargeting it to #{accepted} would change what it MERGES without moving its head, " \
               "so --match-head-commit cannot catch it, and it would drag ##{parent["number"]}'s " \
               "unmerged work onto #{accepted} with it.")
      say.call("  ##{parent["number"]} merges FIRST. Re-review once the parent lands and GitHub " \
               "retargets this PR to #{accepted} on its own.")
      return :refused
    end

    say.call("  retarget #{slug} PR base #{branch} → #{accepted} (mis-based feat PR self-heals: #{why(stack)})")
    return :retargeted if edit.call(branch)

    say.call("  could not retarget #{pr_url} base → #{accepted} — leaving #{slug} submitted")
    :retarget_failed
  end

  # Every refusal reads the same way and always says what is left submitted, so a reviewer
  # never has to guess whether the task moved.
  # EVERY REFUSAL CARRIES ITS REMEDY. A gate that says only "no" is one reviewers learn to
  # route around, and each of these five refuses for a different reason with a different way
  # forward — so the way forward is named rather than left to be re-derived.
  def refuse(say, slug, because, remedy: nil)
    say.call("  REFUSING to merge #{slug}: #{because}.")
    say.call("  → #{remedy}.") if remedy
    say.call("  Leaving #{slug} submitted — nothing retargeted, nothing merged.")
  end
end
