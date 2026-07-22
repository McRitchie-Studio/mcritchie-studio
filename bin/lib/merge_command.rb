# frozen_string_literal: true

# MergeCommand — the pure `gh pr merge` argument vector for the accepted-ladder merge
# (bin/pr-review). Extracted so the --match-head-commit PIN is unit-testable without gh or a
# live PR: the supervisor merges ONLY the head it revalidated, so if the head advances again
# between revalidation and merge (a late zap, a racing push), `gh pr merge --match-head-commit`
# REFUSES rather than silently merging an unvalidated head. A blank head (a gh read fault at
# capture time) falls back to the unpinned merge — the documented degraded path — never a bogus
# empty pin, which gh would reject and stall every merge.
module MergeCommand
  module_function

  def args(pr_url, merge_head = nil)
    argv = ["pr", "merge", pr_url.to_s, "--merge"]
    argv += ["--match-head-commit", merge_head.to_s] unless merge_head.to_s.strip.empty?
    argv
  end
end
