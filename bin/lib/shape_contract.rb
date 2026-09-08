# frozen_string_literal: true

require "yaml"
require_relative "code_diff"

# ShapeContract — "does this task's SHAPE owe a local test cert at all?", asked by
# the G1 cert runner (bin/fast-check) before it refuses a diff for want of tests.
#
# THE DEFECT THIS EXISTS FOR (/tasks/fast-check-ignores-docs-shape, measured
# 2026-09-07 on /tasks/wallet-transport-architecture-doc). config/feature_shapes.yml
# says of the `docs` shape, out loud: `dor_tiers: []`, `full_suite_gate: false`, and
# "a doc change certifies by REVIEW, not a test lane". bin/dor-check honours that in
# two places already — it gates the whole suite-evidence block on
# `shape_def.fetch("full_suite_gate", true)`, and `full_cert_stands_in_for_ci?`
# returns true for a shape that declares no suite. bin/fast-check never asked. So on
# a ONE-FILE MARKDOWN diff in a satellite checkout (where the hub-anchored spine
# resolves nothing) its zero-evidence guard REFUSED and named bin/full-suite-check as
# the remedy — and 316 lines of prose that cannot reach a single test cost a
# ~31-minute turf-monster suite run. Two halves of one gate, holding opposite
# answers to one question.
#
# WHAT IS **NOT** BEING FIXED, and this is the whole design constraint: the
# zero-evidence guard's reasoning is SOUND and is not softened by a single line here.
# "This run would execute ZERO test files" is still a refusal; a linter still cannot
# observe behaviour; a green cert over no tests is still a verdict on evidence that
# does not exist. What this module adds is a PRIOR question the guard never asked —
# *was a suite owed in the first place?* — and it can only ever answer "no" for a
# diff that is OBSERVED to ship nothing a suite could test. A shape whose own config
# says no suite is owed must not be routed to the heaviest command in the house; a
# shape that owes one still is.
#
# TWO FACTS, BOTH REQUIRED, AND THE SECOND IS THE SAFETY.
#
#   1. THE DECLARATION — the shape's own contract in config/feature_shapes.yml says
#      no suite AND no tiers are owed (#suite_owed?, fail-closed).
#   2. THE OBSERVATION — the diff in hand is provably non-behavioral, decided by
#      CodeDiff, the SAME classifier bin/dor-check's exempt-kind gate and the `docs`
#      shape's own `claimable_when` run.
#
# Fact 1 alone is a LABEL, and this file's whole family of bugs is labels standing in
# for evidence: `kind: chore` shipping .github/workflows/ci.yml (PR #512), and a
# `docs`-SHAPED diff carrying app/models/task.rb passing "DoR-to-Merge met" (PR
# #1172). A waiver you unlock by TYPING `docs` is that bug for the third time. So the
# label only ever narrows what the OBSERVATION is allowed to excuse, and an
# unobservable diff excuses nothing (CodeDiff.doc_only? returns false on an empty
# list — "we saw nothing" is not "there is nothing but prose").
#
# WHY doc_only? AND NOT docs_with_guards?. The `docs` shape is claimable on prose
# PLUS the registry-guard tests that pin it (`claimable_when: docs_with_guards_diff`),
# so the looser predicate is the one the SHAPE gate uses. This gate deliberately uses
# the STRICTER one, and the difference is reachable rather than theoretical: a changed
# `test/docs/*_test.rb` maps to ITSELF (FastCert's convention rung), so a docs+guards
# diff normally runs that test and never reaches the zero-evidence guard at all. The
# one way it DOES reach it is a guard test that was DELETED — nothing left on disk to
# run — and a deleted test is precisely the change that needs a suite to prove it
# removed nothing else. doc_only? refuses that; docs_with_guards? would have waived
# it. Strictness is free here and the loose reading costs a real hole.
module ShapeContract
  module_function

  # The shape's stanza from config/feature_shapes.yml, or nil when the file, the
  # `shapes` map, or the named shape is missing. nil is the fail-closed value —
  # #suite_owed? reads it as "assume a suite is owed".
  def definition(config_path, shape)
    name = shape.to_s.strip
    return nil if name.empty?

    shapes = YAML.safe_load(File.read(config_path.to_s))&.fetch("shapes", nil)
    return nil unless shapes.is_a?(Hash)

    shapes[name]
  rescue Errno::ENOENT, Psych::SyntaxError
    nil
  end

  # Does this shape owe test evidence? FAIL-CLOSED in three directions, because the
  # only cost of a false "owed" is a suite run and the cost of a false "not owed" is
  # an uncertified change:
  #   * an unknown / unreadable shape owes one (nil definition);
  #   * `full_suite_gate` DEFAULTS TO TRUE, the same default bin/dor-check reads, so
  #     a shape that forgets to declare it owes one;
  #   * ANY dor_tier owes one, even alongside `full_suite_gate: false`. The two keys
  #     are independent — the header of feature_shapes.yml exists largely to say so
  #     — and a shape with a tier has something a local lane can execute, whatever
  #     the merge gate asks of it.
  def suite_owed?(shape_def)
    return true unless shape_def.is_a?(Hash)
    return true if shape_def.fetch("full_suite_gate", true)

    Array(shape_def["dor_tiers"]).any?
  end

  # THE WHOLE QUESTION, asked once. Returns nil when a cert IS owed (the caller
  # proceeds exactly as before — this is the answer for every code diff), else a hash
  # of the facts that waived it, for the caller's message:
  #
  #   { shape:, files:, message: }
  #
  # `changed` MUST be the rename-aware path view (both sides of an R/C entry — see
  # CodeDiff.paths_from_name_status), or a rename that buries an executable inside a
  # .md destination reads as pure prose. `git diff --name-only` shows only the
  # DESTINATION, so passing it here would re-open the exact hole CodeDiff's header
  # documents. FastCert.classifiable_paths builds the correct view.
  def cert_waiver(shape:, shape_def:, changed:)
    name = shape.to_s.strip
    return nil if name.empty?
    return nil if suite_owed?(shape_def)

    files = Array(changed).map { |f| f.to_s.strip }.reject(&:empty?).uniq
    return nil unless CodeDiff.doc_only?(files)

    { shape: name, files: files, message: waiver_message(name, files) }
  end

  # WHAT THE OPERATOR READS, and it says the one thing a reader must not get wrong:
  # this is the ABSENCE of an owed cert, never a cert. It names both facts (the
  # declaration and the observation) so the waiver can be checked rather than
  # trusted, and it names who re-derives it, because nothing durable is recorded —
  # see the guard in bin/fast-check for why a receipt here would be decoration.
  def waiver_message(shape, files)
    listed = files.size <= 6 ? files.join(", ") : "#{files.take(6).join(', ')}, +#{files.size - 6} more"
    "NO CERT OWED — not certified, and none was required. The task's shape `#{shape}` declares " \
      "`full_suite_gate: false` with no `dor_tiers` (config/feature_shapes.yml: \"a doc change " \
      "certifies by REVIEW, not a test lane\"), AND the OBSERVED diff ships no behaviour — " \
      "#{files.size} file(s), every one prose or inert media: #{listed}." \
      "\n  NO test lane ran and NOTHING is recorded on the task. This is not a green cert over " \
      "zero tests; it is the absence of a cert that was never owed. bin/dor-check re-derives the " \
      "same waiver from the shape at the verdict (it gates its whole suite-evidence block on " \
      "`full_suite_gate`), so the exemption is asked twice and answered from the config both times." \
      "\n  Ship one behavioural file and this waiver is GONE — the diff stops being doc-only and " \
      "the zero-evidence refusal applies again, unchanged."
  end
end
