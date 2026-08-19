# frozen_string_literal: true

# Release::MergeSubject — recover the TASK a merge commit came from, using the
# one convention the cycle already guarantees.
#
# WHY THIS EXISTS. prepare's stale-tree gate (step 3b) refuses when `accepted`
# carries work `release` does not, and tells the operator the commits "reached
# `accepted` with NO TASK BEHIND them", naming three possible causes — a
# conductor zap, a hand-merge, or a review whose `merged` stamp never landed —
# without distinguishing them. When the cause is the third, that diagnosis is
# WRONG: a task does exist, the failure is bookkeeping, and the two-command
# repair is nothing like the hand-landed batch PR the abort prescribes.
#
# The link is deterministic and already in the data. Creating a task seeds
# `worktree_slug` and the `feat/<slug>` branch from its slug, and GitHub writes
# the branch into every merge commit subject:
#
#   Merge pull request #918 from McRitchie-Studio/feat/repair-quarantined-e2e-clusters
#
# so the slug can be read straight back out. No new machinery, no guessing.
#
# NOT EVERY MERGE IS A TASK. The batch promote PR merges a RUNG, not a feature:
#
#   Merge pull request #925 from McRitchie-Studio/accepted
#
# and a rung name is never a task slug. Those, and anything that does not match
# the shape at all, stay unattributable — which is the point: this module must
# NARROW the diagnosis, never weaken the refusal.
class Release
  module MergeSubject
    # Prefixes a task's branch conventionally carries. This is an ALLOW-LIST and
    # it is the whole guard: a branch must have one of these prefixes AND a
    # non-empty remainder. That is what keeps the two shapes that are NOT tasks
    # from resolving — a ladder rung (`accepted`, no slash at all) and a
    # third-party branch (`dependabot/bundler/rails-8.1.4`, a slash but a foreign
    # prefix). An earlier cut carried a separate rung deny-list too; mutation
    # testing showed it could not fail, because the rung shape is already
    # excluded here, so it was removed rather than left as an untested branch.
    TASK_BRANCH_PREFIXES = %w[feat fix chore bug].freeze

    # `Merge pull request #<n> from <owner>/<branch>`. The owner segment is
    # skipped, the rest is the branch (which may itself contain slashes).
    MERGE_SUBJECT = %r{\AMerge pull request \#?\d+ from [^/\s]+/(?<branch>\S+)}.freeze

    module_function

    # The branch a merge commit subject names, or nil when the subject is not a
    # GitHub merge commit at all (a zap, a hand-merge, a squashed commit).
    def branch_from_subject(subject)
      m = MERGE_SUBJECT.match(subject.to_s.strip)
      return nil unless m

      branch = m[:branch].to_s.strip
      branch.empty? ? nil : branch
    end

    # The task slug a branch encodes, or nil when the branch is a ladder rung or
    # carries no task prefix. Returns nil rather than guessing.
    def slug_from_branch(branch)
      name = branch.to_s.strip
      return nil if name.empty?

      prefix, _, rest = name.partition("/")
      return nil unless TASK_BRANCH_PREFIXES.include?(prefix)
      return nil if rest.empty?

      rest
    end

    # Convenience: subject → slug, or nil.
    def slug_from_subject(subject)
      branch = branch_from_subject(subject)
      branch && slug_from_branch(branch)
    end

    # Classify ONE stranded commit against a task index.
    #
    # `task_index` maps slug => { "stage" =>, "merged" => } for the tasks the
    # caller could read. A slug absent from the index is UNATTRIBUTABLE, not
    # "unstamped" — the caller may simply not have fetched it, and an unreadable
    # fact is never a clean fact.
    #
    # Returns one of:
    #   { kind: :lost_stamp,      slug:, stage: }  — task exists, no merged stamp
    #   { kind: :stamped,         slug:, stage:, merged: } — task exists and IS stamped
    #   { kind: :unattributable }                  — no slug, or no such task
    def attribute(subject, task_index)
      slug = slug_from_subject(subject)
      return { kind: :unattributable } unless slug

      task = (task_index || {})[slug] || (task_index || {})[slug.to_sym]
      return { kind: :unattributable } unless task.is_a?(Hash)

      merged = (task["merged"] || task[:merged]).to_s.strip
      stage  = (task["stage"] || task[:stage]).to_s

      return { kind: :lost_stamp, slug: slug, stage: stage } if merged.empty?

      { kind: :stamped, slug: slug, stage: stage, merged: merged }
    end

    # Every task slug named by a stranded-commit map, deduped and in order.
    #
    # `stranded` is the { "<repo>" => [{ "sha" =>, "subject" => }, …] } shape the
    # stale-tree gate builds. THIS FUNCTION EXISTS BECAUSE ITS CALLER WAS
    # UNTESTED GLUE: the first cut inlined `Array(stranded).values`, and
    # `Kernel#Array` on a Hash yields [key, value] PAIRS, which have no `values`
    # method. The NoMethodError was swallowed by the caller's rescue, so the
    # gather returned {} for every input and the whole attribution feature was
    # dead in the shipped command while its model tests stayed green. Pulling the
    # gather into a pure function is what makes that reachable by a unit test.
    #
    # Hash() rather than Array(): Hash(nil) is {}, so nil-safety is preserved
    # without the pair-vs-value confusion.
    def slugs_from_commits(stranded)
      Hash(stranded).values.flatten.filter_map do |commit|
        next unless commit.is_a?(Hash)

        slug_from_subject(commit["subject"] || commit[:subject])
      end.uniq
    end

    # The one-line repair for a lost stamp, ready to print. STAGE-AWARE: a task
    # already at `reviewed` needs only the stamp, and printing a redundant stage
    # move invites the reader to re-run a transition that is already done.
    def lost_stamp_repair(slug, stage = nil)
      stamp = "bin/task merged #{slug} accepted"
      return stamp if stage.to_s == "reviewed"

      "#{stamp} && bin/task move #{slug} reviewed"
    end
  end
end
