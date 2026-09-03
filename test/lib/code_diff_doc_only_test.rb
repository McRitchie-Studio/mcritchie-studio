# frozen_string_literal: true

# [unit] CodeDiff.doc_only? and docs_with_guards? — the classifier behind the
# `docs` shape's claim guard (`claimable_when: docs_with_guards_diff` since
# 2026-09-03; doc_only? remains the exempt-KIND gate's half and the core the
# guard-test rule builds on). Run directly:
#   ruby -Itest test/lib/code_diff_doc_only_test.rb
#
# WHAT IT IS GUARDING. Until 2026-09-02 the `docs` shape's zero tiers and waived
# full-suite cert were unlocked by TYPING `docs` — the diff was never consulted.
# Measured on PR #1172: a `docs`-shaped diff carrying test/integration/
# open_pr_receipt_visibility_test.rb was told "DoR-to-Merge met", with no tier and
# no cert demanded and no line saying either had been skipped.
#
# The fix reuses CodeDiff, the classifier bin/dor-check's exempt-KIND gate already
# runs on the same diff — so the two can never answer one question two ways. That
# reuse is the whole design, and it is what these tests pin: the positive predicate
# has to agree with code_files, and it has to REFUSE the empty list, which
# code_files alone cannot express.
require "minitest/autorun"
require_relative "../../bin/lib/code_diff"

class CodeDiffDocOnlyTest < Minitest::Test
  # --- the case that motivated the guard -------------------------------------

  # THE REGRESSION, verbatim: PR #1172's diff. A doc change that also fixes one
  # test file is the ORDINARY doc task (it is most doc tasks that repair an inert
  # test), which is why the hole was reachable without anyone doing anything odd.
  def test_a_test_file_riding_a_prose_diff_is_not_doc_only
    files = ["docs/agents/note.md", "test/integration/open_pr_receipt_visibility_test.rb"]
    refute CodeDiff.doc_only?(files),
           "a diff carrying a TEST FILE must not be claimable as doc-only — test/ is executable, and " \
           "`test-only` is the shape that exists for it. This is PR #1172's exact diff."
    assert_equal ["test/integration/open_pr_receipt_visibility_test.rb"], CodeDiff.code_files(files),
                 "the offender list is what a refusal NAMES, so it must carry the disqualifying file"
  end

  # Production code rode the same hole just as easily — the filing recorded a test
  # file, but nothing in the gate was specific to tests.
  def test_app_code_riding_a_prose_diff_is_not_doc_only
    refute CodeDiff.doc_only?(["docs/agents/note.md", "app/models/task.rb"])
  end

  # --- the empty case, which is the reason this predicate exists at all -------

  # AN EMPTY LIST IS FALSE. "We observed nothing" and "there is nothing but prose"
  # are different facts; collapsing them is how a blind checkout would be handed
  # the claim. code_files([]) is legitimately [] — that is precisely why a caller
  # reading only that half cannot tell a prose diff from an unreadable one, and why
  # this predicate is not a convenience wrapper.
  def test_an_empty_diff_is_not_doc_only
    refute CodeDiff.doc_only?([]),
           "an empty observation is the absence of evidence, not evidence of a doc-only diff"
    assert_empty CodeDiff.code_files([]),
                 "code_files CANNOT express the difference — if this ever became non-empty the asymmetry " \
                 "documented on doc_only? would be gone and this test would be pinning nothing"
  end

  def test_a_list_of_blanks_is_not_doc_only
    refute CodeDiff.doc_only?(["", "  ", nil]),
           "whitespace is not a file; a diff that reduces to nothing observed must fail closed"
  end

  # --- what DOES earn the claim ----------------------------------------------

  def test_prose_only_diff_is_doc_only
    assert CodeDiff.doc_only?(["docs/agents/note.md", "README.md", "AGENTS.md"])
  end

  def test_inert_media_beside_prose_is_doc_only
    assert CodeDiff.doc_only?(["docs/img/flow.png", "docs/agents/note.md"]),
           "a diagram swap renders and never executes; gating it would make the cheap shape expensive, " \
           "which is the fix this change deliberately did NOT make"
  end

  # --- the three edges the shape's notes commit to, pinned so they stay true ---

  # LOCATION BUYS NOTHING. The same rule CodeDiff's header refuses a `docs/` prefix
  # for: docs/agents/setup.sh is mode 100755 (the fresh-machine bundle + DB
  # bootstrap). Where a file was FILED is a declaration; what it IS is evidence.
  def test_an_executable_filed_under_docs_is_not_doc_only
    refute CodeDiff.doc_only?(["docs/agents/setup.sh"]),
           "a `docs/` prefix rule would hand a full exemption to a 100755 file living under docs/"
  end

  # HUNK GRANULARITY IS REFUSED ON PURPOSE. A comment-only edit to a .yml is NOT
  # doc-only: "this hunk is only comments" is a parse an author can talk the gate
  # out of, so the honest granularity is the FILE. The cost of the strict answer is
  # one tier line on another shape; the cost of the loose one is the gate. This
  # test exists because the config's notes PROMISE this answer to the next reader.
  def test_a_config_file_is_not_doc_only_even_though_it_may_be_comment_only
    refute CodeDiff.doc_only?(["config/e2e_lane.yml"]),
           "the shape's notes commit to this answer explicitly — if it ever flips, that written rule is a lie"
  end

  # A CI workflow is PR #512's exact escape, one gate over. It must not become
  # prose because a doc task happened to touch it.
  def test_a_workflow_is_not_doc_only
    refute CodeDiff.doc_only?(["docs/agents/note.md", ".github/workflows/ci.yml"])
  end

  # --- agreement with the half the exempt-KIND gate already uses --------------

  # THE DESIGN INVARIANT, stated as a property rather than a case list: the shape
  # claim and the kind exemption must never disagree, because the defect being
  # fixed WAS them disagreeing — the kind gate refused a behavioral `kind: docs`
  # diff, and the `docs` SHAPE granted the same exemption one step later.
  def test_doc_only_agrees_with_code_files_on_every_non_empty_list
    [
      ["README.md"],
      ["app/models/task.rb"],
      ["docs/agents/note.md", "test/lib/x_test.rb"],
      ["docs/img/flow.png", "LICENSE"],
      ["Gemfile", "docs/agents/note.md"]
    ].each do |files|
      assert_equal CodeDiff.code_files(files).empty?, CodeDiff.doc_only?(files),
                   "doc_only? disagreed with code_files on #{files.inspect} — these are one truth, and two " \
                   "answers to one question is the exact defect this guard was written to close"
    end
  end

  # --- docs_with_guards? — the docs+guard-test pattern ------------------------
  # (/tasks/docs-shape-rejects-guard-test: every SOP wants the registry-guard
  # test that pins it, and doc_only? forced authors to delete the guard or
  # mislabel the shape. The claim rule is TYPE AND LOCATION together.)

  # THE PATTERN, verbatim: PR #1169's diff shape — an SOP plus the registry
  # guard that pins its rows.
  def test_prose_plus_a_docs_guard_test_claims_docs_with_guards
    files = ["docs/agents/agents/steffon/sops/credential-filing.md",
             "docs/agents/index.md",
             "test/docs/sop_registry_docs_test.rb"]

    assert CodeDiff.docs_with_guards?(files)
    refute CodeDiff.doc_only?(files), "doc_only? must still refuse — the two predicates differ EXACTLY here"
    assert_empty CodeDiff.non_guard_code_files(files)
  end

  # Location without type earns nothing: a helper.rb under test/docs/ is
  # unclassified behavior, not a guard test — the bare-directory rule the
  # classifier's own header forbids.
  def test_a_non_test_file_under_test_docs_disqualifies_the_claim
    files = ["docs/agents/note.md", "test/docs/helper.rb"]

    refute CodeDiff.docs_with_guards?(files)
    assert_equal ["test/docs/helper.rb"], CodeDiff.non_guard_code_files(files)
  end

  # Type without location earns nothing either: an app-subject test riding a
  # prose diff is the ORIGINAL regression (PR #1172), not the guard pattern.
  def test_a_test_outside_test_docs_disqualifies_the_claim
    refute CodeDiff.docs_with_guards?(["docs/agents/note.md",
                                       "test/integration/open_pr_receipt_visibility_test.rb"])
  end

  # Guard tests with NO prose are test-only's stricter business (full-suite cert
  # + [control] line) — a tierless docs claim must not become the cheap door.
  def test_guard_tests_alone_do_not_claim_docs_with_guards
    refute CodeDiff.docs_with_guards?(["test/docs/sop_registry_docs_test.rb"])
  end

  # The doctrine's own counterexample: an executable filed under docs/ still
  # disqualifies, exactly as it does for doc_only?.
  def test_an_executable_under_docs_disqualifies_docs_with_guards
    refute CodeDiff.docs_with_guards?(["docs/agents/setup.sh", "docs/agents/note.md",
                                       "test/docs/sop_registry_docs_test.rb"])
  end

  def test_an_empty_diff_is_not_docs_with_guards
    refute CodeDiff.docs_with_guards?([])
    refute CodeDiff.docs_with_guards?(["  ", nil])
  end

  # Pure prose still claims: the widened rule is a superset of doc_only?, so
  # every previously-claimable docs diff stays claimable.
  def test_docs_with_guards_is_a_superset_of_doc_only
    [
      ["README.md"],
      ["docs/img/flow.png", "LICENSE"],
      ["docs/agents/note.md"]
    ].each do |files|
      assert CodeDiff.docs_with_guards?(files),
             "#{files.inspect} claims doc_only? but not docs_with_guards? — the widening must never shrink"
    end
  end
end
