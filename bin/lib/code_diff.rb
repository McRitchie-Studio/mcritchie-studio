# frozen_string_literal: true

# Does this diff ship BEHAVIOR? The one classifier behind every "is this task
# exempt from the shape/test-tier gate" decision (bin/dor-check's chore gate and
# bin/session-preflight's shape preview both call it, so the two can never drift).
#
# WHY THIS IS A DENYLIST, NOT AN ALLOWLIST
#
# It used to be an allowlist: CODE_PATH_PREFIXES = %w[app/ lib/ bin/ config/ db/],
# and anything outside those five prefixes counted as "not code" — so a `kind:
# chore` task kept its exemption. That is a gate you pass by DEFAULT, and it
# failed exactly as you'd expect: task run-ci-on-release-branch (PR #512, kind:
# chore) shipped .github/workflows/ci.yml — a change to how CI runs on every
# repo, plus a new test file — and dor-check printed "n/a — non-code task (kind:
# chore); DoR n/a → ready to advance". No tier was ever demanded. Gemfile,
# Rakefile, package.json, .rubocop.yml, Procfile and test/ had the same hole.
#
# An allowlist of "what counts as code" is unbounded and is maintained by
# whoever last got burned. So the polarity is inverted here: a file is
# non-behavioral ONLY if it is provably prose or inert media — everything else
# is behavior. A new file type (a Dockerfile, a .tool-versions, a workflow) is
# gated the day it lands, without anyone remembering to add it to a list.
#
# And the skip set is keyed on the file's TYPE, never on its DIRECTORY. The first
# cut of this fix carried a `docs/` prefix rule, which is prose-by-ASSERTION —
# the same declaration-over-evidence bug, one granularity down. It would have
# exempted docs/agents/setup.sh (mode 100755) and rolio's docs/build/workflow.js.
# Where a file was FILED is a declaration; what it IS is evidence.
# This is the audit's thesis applied one gate earlier: a check you satisfy by
# DECLARING a `kind` rather than by EVIDENCE is not a check.
# See docs/agents/audits/release-gate-and-devops-process-review-2026-07-12.md.
#
# Deliberately NOT special-cased:
#   * test/**            — executable, and the tier line it earns is TRUE (the
#                          author just wrote the tests); costs one honest line.
#   * Gemfile/Gemfile.lock — a dependency bump changes the resolved gem graph.
#                          That IS behavior, and it is the change most likely to
#                          go out untested because it "feels like a chore".
#   * comment-only edits inside a code file — deciding "this hunk is only
#                          comments" means trusting a parse of the diff, which is
#                          another inference the gate can be talked out of. The
#                          honest granularity is the FILE. Gating a comment-only
#                          .rb edit costs one tier line naming the suite that
#                          already covers it; mis-detecting one disarms the gate.
module CodeDiff
  # Kinds that MAY skip the shape/test-tier gate — but only ever on a diff that is
  # OBSERVED to be doc-only. The label alone buys nothing.
  EXEMPT_KINDS = %w[chore cleanup docs].freeze

  # A file is classified by WHAT IT IS (its type), never by WHERE IT LIVES.
  #
  # There is deliberately no DOC_PREFIXES / "docs/ is prose" rule. A directory
  # allowlist is prose-BY-ASSERTION — the same declaration-over-evidence error
  # this whole gate exists to remove, just one granularity down. It is not
  # hypothetical: `docs/agents/setup.sh` is mode 100755 (the fresh-machine bundle
  # + DB bootstrap), `docs/agents/patches/*.patch` are applied to the Codex
  # runtime, and rolio ships `docs/build/workflow.js`. A `docs/`-prefix rule hands
  # every one of them a full exemption — re-opening THIS bug one directory over.
  # Classify by type, not by where someone filed it.

  # Prose file types, anywhere in the tree (README.md, a SOP under docs/,
  # .github/ISSUE_TEMPLATE/bug.md, AGENTS.md, CLAUDE.md).
  DOC_EXTENSIONS = %w[.md .markdown .mdx .rdoc].freeze

  # Inert media: renders, never executes. Keeps a screenshot/diagram/icon swap
  # (docs/img/flow.png) from demanding a test tier.
  INERT_MEDIA_EXTENSIONS = %w[.png .jpg .jpeg .gif .svg .webp .ico .pdf].freeze

  # Prose and inert metadata identified by BASENAME. Note `.txt` is NOT a blanket
  # prose extension: public/robots.txt is production-served behavior and
  # test/fixtures/files/*.txt is test input. Only the prose-by-convention names
  # below skip.
  DOC_BASENAMES = %w[
    LICENSE LICENSE.txt LICENSE.md COPYING NOTICE NOTICE.txt AUTHORS AUTHORS.txt
    CODEOWNERS README.txt CHANGELOG.txt .gitignore .gitattributes
  ].freeze

  # True when this path cannot change behavior — the ONLY thing that earns a skip.
  def self.non_behavioral?(path)
    file = path.to_s.strip.delete_prefix("./")
    return false if file.empty?

    extension = File.extname(file).downcase
    return true if DOC_EXTENSIONS.include?(extension)
    return true if INERT_MEDIA_EXTENSIONS.include?(extension)

    DOC_BASENAMES.include?(File.basename(file))
  end

  def self.behavioral?(path)
    !non_behavioral?(path)
  end

  # The subset of `files` that ships behavior. Empty == a provably doc-only diff.
  def self.code_files(files)
    Array(files).map { |f| f.to_s.strip }.reject(&:empty?).select { |f| behavioral?(f) }
  end

  # May this file list claim a doc-only contract? The positive form of code_files,
  # and the predicate behind `claimable_when: doc_only_diff` — which no shape
  # declares any more (the `docs` shape moved to `docs_with_guards_diff` on
  # 2026-09-03). The rule and its dor-check arm are KEPT deliberately: doc_only?
  # is still what the exempt-KIND gate runs, and docs_with_guards? builds on it.
  #
  # AN EMPTY LIST IS FALSE, exactly as in TestOnlyDiff.test_only?. "We observed
  # nothing" and "there is nothing but prose" are different facts, and collapsing
  # them is how a blind checkout grants the claim. bin/dor-check's exempt-KIND gate
  # has always drawn that line (its `indeterminate` branch); this puts the same rule
  # where a SHAPE claim can reach it, rather than re-deriving it at the call site —
  # two copies of one truth being the drift these guards exist to catch.
  #
  # NOTE THE ASYMMETRY WITH code_files, and that it is deliberate: `code_files([])`
  # is legitimately empty (nothing behavioral was seen), so a caller that reads only
  # that half cannot tell a prose diff from a blind one. This predicate can.
  def self.doc_only?(files)
    list = Array(files).map { |f| f.to_s.strip }.reject(&:empty?)
    return false if list.empty?

    code_files(list).empty?
  end

  # ── The docs+guard pattern (/tasks/docs-shape-rejects-guard-test) ──────────
  #
  # Every SOP added to this repo wants the registry-guard test that pins its
  # rows (test/docs/sop_registry_docs_test.rb), and doc_only? correctly refuses
  # a diff that ships one — a test file is behavior. That left an author two
  # exits, both worse than the gate's purpose: delete a good test, or mislabel
  # the shape. These predicates give that PAIRED change an honest home.
  #
  # THE RULE IS TYPE **AND** LOCATION TOGETHER, deliberately — not the
  # directory allowlist the header above forbids. `test/docs/anything` alone
  # earns nothing (a helper.rb there is still unclassified behavior); the file
  # must ALSO be a test by type (`*_test.rb`). What location contributes is
  # SUBJECT: a test under test/docs/ asserts about documentation, which is the
  # one kind of behavior a docs claim can carry without becoming a code claim.
  DOCS_GUARD_DIR = "test/docs/"

  def self.docs_guard_test?(path)
    file = path.to_s.strip.delete_prefix("./")
    file.start_with?(DOCS_GUARD_DIR) && file.end_with?("_test.rb")
  end

  # The offender list for a docs-with-guards claim: behavioral files that are
  # not docs-guard tests. Used to NAME what disqualified the claim.
  def self.non_guard_code_files(files)
    code_files(files).reject { |f| docs_guard_test?(f) }
  end

  # May this file list claim the docs shape? Prose (plus inert media) with any
  # number of docs-guard tests riding along. Two refusals stated on purpose:
  #   * an EMPTY list refuses — "we observed nothing" is not "nothing but prose"
  #     (same line doc_only? draws);
  #   * a diff with NO prose refuses — guard tests alone are a test-only change,
  #     and test-only's STRICTER contract (full-suite cert + [control] line)
  #     must not be dodged by filing pure test code under a tierless docs claim.
  def self.docs_with_guards?(files)
    list = Array(files).map { |f| f.to_s.strip }.reject(&:empty?)
    return false if list.empty?
    return false if list.all? { |f| behavioral?(f) }

    non_guard_code_files(list).empty?
  end

  # BOTH SIDES OF A RENAME. A rename has two paths, and every path-list view of a
  # diff shows you only ONE — the destination. `git diff --name-only` collapses
  # `R100 bin/deploy.sh docs/deploy-notes.md` to `docs/deploy-notes.md`, and
  # GitHub's `gh pr view --json files` exposes only {additions, changeType,
  # deletions, path}. So a commit that renames an EXECUTABLE into a .md presents
  # as one prose file and takes a full exemption — while having DELETED a script
  # from bin/. The behavior change is the REMOVAL, and it is invisible in the new
  # path. (The reverse, docs/x.md → bin/x.sh, always gated: its new path is
  # behavioral.) This is the same bug's third face — first the `kind` LABEL, then
  # the `docs/` DIRECTORY, now the NEW PATH: each a declaration ABOUT the change
  # standing in for evidence OF it. A rename is precisely where the path lies,
  # because half the content isn't in it.
  #
  # So: parse `--name-status -M` and emit BOTH paths for a rename (R) or copy (C).
  # Either side behavioral → the diff gates. `docs/a.md → docs/b.md` still skips.
  # An unparseable line yields nothing to classify, so callers fall back to their
  # indeterminate (fail-closed) path rather than inventing a clean diff.
  def self.paths_from_name_status(raw)
    raw.to_s.split("\n").flat_map do |line|
      fields = line.split("\t").map(&:strip).reject(&:empty?)
      next [] if fields.size < 2

      status = fields[0]
      # R100 old new / C75 old new — take BOTH. Everything else (M/A/D/T) is one path.
      status.start_with?("R", "C") && fields.size >= 3 ? [fields[1], fields[2]] : [fields[1]]
    end
  end
end
