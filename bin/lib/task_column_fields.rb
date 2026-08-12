# frozen_string_literal: true

# TaskColumnFields — the rendering rule for the handful of load-bearing task
# fields that live as TOP-LEVEL Task COLUMNS while nearly every one of their
# neighbours lives in `metadata["devops"]`.
#
# WHY THIS FILE EXISTS — a defect that cost three agents in 24 hours
#
# `merged` (nil / accepted / release / main) is the git-location stamp review
# writes when it lands a feat PR on `accepted`. It is the ONE field whose absence
# makes the release sweep skip a `reviewed` task as a HELD anomaly, so it gets
# read back constantly. It is also a top-level column — and it was NOT printed by
# `bin/task show --verbose`, which prints its neighbours `pr_url`, `local_url`,
# `approval_status`, the claim state, `test_plan` and `checks_run` (all devops).
#
# So an agent verifying the stamp reached for `.metadata.devops.merged`, got
# `null` — for EVERY task, stamped or not, because nothing ever writes there —
# and concluded the write had dropped. On 2026-08-11/12 that produced a
# nearly-filed false "stamp did not persist" incident plus a needless re-run, a
# second agent briefly reading it as the known stamp-heal bug, and a MEMORY entry
# recording the false conclusion as a real persistence bug (since marked
# UNCONFIRMED). Every one of those was the same inference: "no output" → "dropped
# write".
#
# THE RULE THIS MODULE ENCODES — three states, never two
#
# The whole cost was ambiguity between "the field is empty" and "the tool does
# not report the field". A bare `-` beside `pr_url` reads as the first; printing
# nothing reads as the second; and the two were indistinguishable. So every
# top-level column renders as exactly one of:
#
#   SET        → the value ("accepted")
#   UNSET      → a definite negative IN WORDS ("not merged"), never `-`
#   UNREPORTED → loud, and visibly different from UNSET, for the case where the
#                board payload carries no such key at all (an older board, a
#                trimmed serializer, a record fetched from a different endpoint)
#
# UNREPORTED is the state that had no glyph before. It is the honest answer to
# "does this task have a merged stamp?" when the tool genuinely cannot say, and
# keeping it distinct from UNSET is the point of the module.
#
# Callers pair the value with LOCATOR so the read-back also teaches WHERE the
# field lives — the actual cause of all three incidents was the lookup path, not
# the value.
module TaskColumnFields
  # The location note, printed beside the values. Short on purpose: it is the one
  # sentence that would have saved all three agents.
  LOCATOR = "top-level Task columns — metadata.devops.<name> is ALWAYS null"

  # What UNSET means, per field, in words. A field is listed here precisely
  # because "empty" has a meaning worth stating out loud.
  UNSET_READS = {
    "merged" => "not merged",
    "release_slug" => "not on a release"
  }.freeze

  # What UNREPORTED prints. Deliberately shouty and self-explaining: it is rare,
  # and the reader must not mistake it for the empty case.
  UNREPORTED_READS = "UNREPORTED (this board did not return the field)"

  module_function

  # Classify a fetched task record's top-level field. Returns :set, :unset, or
  # :unreported. `task` is the parsed API record (`data`), not the devops hash.
  #
  # NOTE the ordering: key-presence is checked BEFORE the value, because a
  # present-but-nil key and a missing key are the two states this module exists
  # to separate, and `task[key]` collapses them into the same nil.
  def state(task, key)
    return :unreported unless task.is_a?(Hash) && task.key?(key)

    task[key].to_s.strip.empty? ? :unset : :set
  end

  # The rendered value for one top-level field — never a bare "-", so the reader
  # can always tell an empty column from an unreported one.
  def read(task, key)
    case state(task, key)
    when :set then task[key].to_s.strip
    when :unset then UNSET_READS.fetch(key, "none")
    else UNREPORTED_READS
    end
  end

  # `label: value` for one field, ready to join onto a line.
  def pair(task, key)
    "#{key}: #{read(task, key)}"
  end
end
