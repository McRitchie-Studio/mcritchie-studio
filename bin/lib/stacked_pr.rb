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
# ONE PREDICATE, TWO CALLERS. bin/ship (the builder half) and bin/pr-review (the reviewer
# half) ask the same question and must not answer it differently; the reviewer half was
# filed precisely because the two had drifted for a release. What each caller DOES with the
# answer still differs — ship re-roots, review refuses — and that stays theirs.
#
# AN EMPTY BASE IS NOT AN ANSWER. `gh pr list --head "" --state open` is NO FILTER to real
# gh and returns EVERY open PR, so an unread or absent base would otherwise name the first
# open PR as the parent and preserve a mis-based PR on a coincidence. :no_base, like
# :unreadable, falls to the repair.
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
  # test cannot see a branch that has been disabled. MEASURED while building this guard: a
  # mutant that replaced the refusal's condition with `if false` left the source assertions
  # GREEN, because the refusal TEXT was still sitting there in dead code. So the decision, the
  # refusal, and the retarget all live in this function, where a test drives them with spies
  # and can assert what was NOT called.
  #
  # `list`, `edit` and `say` are the caller's own gh reader, gh writer, and printer.
  # => :proceed | :refused | :retargeted | :retarget_failed
  def guard_base(base:, accepted:, slug:, pr_url:, list:, edit:, say:)
    branch = base.to_s.strip
    return :proceed if branch.empty? || branch == accepted

    stack = assess(branch) { |head| list.call(head) }

    if stack[:state] == :stacked
      parent = stack[:parent]
      say.call("  REFUSING to merge #{slug}: its PR is based on #{branch}, which is open PR " \
               "##{parent["number"]} (#{parent["url"]}) — a deliberate STACK, not a mis-based PR.")
      say.call("  Retargeting it to #{accepted} would change what it MERGES without moving its head, " \
               "so --match-head-commit cannot catch it, and it would drag ##{parent["number"]}'s " \
               "unmerged work onto #{accepted} with it.")
      say.call("  ##{parent["number"]} merges FIRST. Leaving #{slug} submitted; re-review once the " \
               "parent lands and GitHub retargets this PR to #{accepted} on its own.")
      return :refused
    end

    say.call("  retarget #{slug} PR base #{branch} → #{accepted} (mis-based feat PR self-heals: #{why(stack)})")
    return :retargeted if edit.call(branch)

    say.call("  could not retarget #{pr_url} base → #{accepted} — leaving #{slug} submitted")
    :retarget_failed
  end
end
