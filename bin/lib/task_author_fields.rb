# frozen_string_literal: true

# TaskAuthorFields — the rendering rule for WHO WORKED A TASK, as distinct from
# who the task is ASSIGNED to.
#
# WHY THIS FILE EXISTS — two false alarms in one day
#
# `bin/task show <slug>` printed one line beginning `agent:`, and it rendered the
# top-level `agent_slug` COLUMN — the ASSIGNEE. It did not render
# `metadata.devops.built_by`, which is the field `bin/reviewer-select` actually
# reads to keep a soul off their own PR.
#
# The two disagree ROUTINELY, and not by accident: `bin/task move <slug> building
# --actor <soul>` stamps `built_by` through Task#builder_to_stamp rule 1 and sets
# no `agent_slug` at all. Measured 2026-08-30 over four tasks built that way,
# three printed `agent: -` while being correctly stamped:
#
#   gem-track-reads-main             built_by="avi"      agent_slug=nil
#   empty-token-falls-back-silently  built_by="jasper"   agent_slug=nil
#   release-renewer-outlives-ship    built_by="shannon"  agent_slug=nil
#   wire-doctor-to-codex-inspect     built_by="steffon"  agent_slug="steffon"
#
# The operating model tells every agent that `built_by` is load-bearing (it is
# the only input reviewer-select has, and an unknown author makes it REFUSE), so
# agents check it — and the surface they naturally reach for answered a different
# question under a similar-looking name, in a way that reads as an alarm. Two
# agents duly reported a blank builder that was in fact stamped; a third instance
# was avoided only because a conductor knew to read `--json` instead.
#
# THE RULE THIS MODULE ENCODES — a label must say what it shows
#
# Plumbing `built_by` to the same `agent:` label would have been the same defect
# in a new costume, so the two facts are now printed under two names:
#
#   assignee: → the `agent_slug` COLUMN. UNSET reads "unassigned", IN WORDS.
#   builders: → the AUTHOR SET. UNSET reads "NOT STAMPED", loudly, because an
#               unstamped task is the state that makes review fail closed.
#
# `-` is deliberately absent from both. It was the glyph that read as "nothing
# to tell you" for a field that had plenty to tell.
#
# WHY A SET, NOT A SLUG. `built_by` holds ONE slug and re-points on a re-claim,
# while a task can have SEVERAL authors — a session limit kills a builder
# mid-work and another soul finishes it. `devops.builders` is the server-owned,
# append-only record of that, and ReviewerSelector excludes the whole union. This
# module renders the same union so the display and the selector cannot disagree
# about who built a task. It is correct for a task stamped BEFORE the accumulator
# existed too (empty `builders`, populated `built_by`), and for one stamped after
# it grew a second author.
#
# WHAT IT DELIBERATELY DOES NOT CLAIM. ReviewerSelector filters every name
# through Task.soul? — the ROSTER, which is DB-backed and unreachable from a
# plain Ruby CLI. So this module applies the weaker HANDLE-SHAPE test only, and
# its output describes what the RECORD holds rather than predicting the
# selector's verdict. A roster typo (`shanon`) therefore still renders as a name
# here while reviewer-select refuses — which is why the locator sends the reader
# to the selector for the verdict instead of implying one.
module TaskAuthorFields
  # The location note, printed beside the values. It is the sentence that would
  # have saved both false alarms: it names WHICH store each fact lives in, which
  # was the actual error — not the values.
  LOCATOR = "builders = metadata.devops.builders + built_by (the author set " \
            "bin/reviewer-select excludes); assignee = the agent_slug column"

  # A soul HANDLE's shape — Task::SOUL_SLUG, re-spelled because bin/task runs
  # without Rails. It is the weaker half of Task.soul? (shape, not roster), and
  # it exists here for one job: keeping a session UUID or an operator email from
  # rendering as a named author. Those are the values a bare `bin/task move`
  # leaves on the record, and counting them would let this line report an author
  # on precisely the task where the selector reports none.
  HANDLE = /\A[a-z]+(?:-[a-z]+)*\z/

  # What an EMPTY author set prints. Shouty on purpose: it is the state in which
  # `bin/reviewer-select` fails closed, so it must not read like an idle blank.
  UNSTAMPED_READS = "NOT STAMPED"

  # What an empty `agent_slug` prints — a definite negative in words, and
  # visibly a different KIND of fact from UNSTAMPED_READS above. Telling these
  # two apart is the whole point: "nobody is assigned" is ordinary, "nobody is
  # recorded as having built it" is a review blocker.
  UNASSIGNED_READS = "unassigned"

  # Appended when the record holds an author it CANNOT NAME
  # (`devops.builders_unattributed` — a session that claimed or shipped the task
  # while naming no soul). The named authors are still true; the set is just not
  # all of them, and a reader who takes a partial set for a complete one is
  # exactly who this line is for.
  INCOMPLETE_SUFFIX = " +1 UNNAMED"

  module_function

  # The devops hash of a fetched API record (`data`), never nil.
  def devops(task)
    return {} unless task.is_a?(Hash)

    task.dig("metadata", "devops") || {}
  end

  # Every author the record NAMES, in ReviewerSelector's order — `built_by`
  # first (so a single-author task reads as itself), then the append-only
  # `builders` history. Non-handles are dropped here and reported by #unnamed.
  def names(task)
    dv = devops(task)
    ([dv["built_by"]] + Array(dv["builders"]))
      .map { |slug| slug.to_s.strip }
      .select { |slug| slug.match?(HANDLE) }
      .uniq
  end

  # On-record values that cannot be a soul handle — a session UUID left by a
  # bare `bin/task move`, an operator email. Returned separately rather than
  # rendered as authors, because the selector cannot exclude them either.
  def unnamed(task)
    dv = devops(task)
    ([dv["built_by"]] + Array(dv["builders"]))
      .map { |slug| slug.to_s.strip }
      .reject(&:empty?)
      .reject { |slug| slug.match?(HANDLE) }
      .uniq
  end

  # The session that worked this task while naming no soul, or nil. Present
  # means the author set is INCOMPLETE.
  def unattributed(task)
    devops(task).fetch("builders_unattributed", "").to_s.strip
                .then { |value| value.empty? ? nil : value }
  end

  # The rendered author set — never a bare "-".
  def read(task)
    named = names(task)
    return read_unstamped(task) if named.empty?

    "#{named.join(", ")}#{unattributed(task) ? INCOMPLETE_SUFFIX : ""}"
  end

  # The empty case, which is two different empties. A record holding ONLY a
  # session id has something to show the reader — it is the tell that a build
  # claim ran without `--actor <soul>` — and hiding it behind a bare
  # "NOT STAMPED" would send them looking for a write that did happen.
  def read_unstamped(task)
    on_record = unnamed(task)
    return UNSTAMPED_READS if on_record.empty?

    "#{UNSTAMPED_READS} (on record, not a soul handle: #{on_record.join(", ")})"
  end

  # The `agent_slug` COLUMN — the assignee, which is NOT the author.
  def assignee_read(task)
    value = task.is_a?(Hash) ? task["agent_slug"].to_s.strip : ""
    value.empty? ? UNASSIGNED_READS : value
  end

  def pair(task) = "builders: #{read(task)}"

  def assignee_pair(task) = "assignee: #{assignee_read(task)}"

  # The raw sources, one per name, for `show --verbose`. Printed UNCONDITIONALLY
  # and never as a bare "-": this is the line an agent verifies a stamp on, and a
  # field that vanishes when empty is the ambiguity this module exists to remove.
  def source_line(task)
    dv = devops(task)
    builders = Array(dv["builders"]).map { |slug| slug.to_s.strip }.reject(&:empty?)
    [
      "built_by: #{or_unstamped(dv["built_by"])}",
      "builders: #{or_unstamped(builders.join(", "))}",
      "unattributed: #{unattributed(task) || "none"}"
    ].join("   ")
  end

  # "" and nil both mean absent, and absent reads as UNSTAMPED_READS — the same
  # never-a-bare-dash rule the rest of this module follows.
  def or_unstamped(value)
    value.to_s.strip.empty? ? UNSTAMPED_READS : value.to_s.strip
  end
end
