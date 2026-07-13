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
# non-behavioral ONLY if it is provably prose or inert metadata — everything
# else is behavior. A new file type (a Dockerfile, a .tool-versions, a workflow)
# is gated the day it lands, without anyone remembering to add it to a list.
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

  # Prose trees. Anything under here is documentation, including its images.
  DOC_PREFIXES = %w[docs/].freeze

  # Prose file types, anywhere in the tree (README.md, CHANGELOG.md, a SOP under
  # docs/, .github/ISSUE_TEMPLATE/bug.md, AGENTS.md, CLAUDE.md).
  DOC_EXTENSIONS = %w[.md .markdown .mdx .rdoc .txt].freeze

  # Inert metadata that cannot execute and cannot change runtime behavior.
  DOC_BASENAMES = %w[LICENSE LICENSE.txt COPYING NOTICE AUTHORS CODEOWNERS .gitignore .gitattributes].freeze

  # True when this path cannot change behavior — the ONLY thing that earns a skip.
  def self.non_behavioral?(path)
    file = path.to_s.strip.delete_prefix("./")
    return false if file.empty?
    return true if DOC_PREFIXES.any? { |prefix| file.start_with?(prefix) }
    return true if DOC_EXTENSIONS.include?(File.extname(file).downcase)

    DOC_BASENAMES.include?(File.basename(file))
  end

  def self.behavioral?(path)
    !non_behavioral?(path)
  end

  # The subset of `files` that ships behavior. Empty == a provably doc-only diff.
  def self.code_files(files)
    Array(files).map { |f| f.to_s.strip }.reject(&:empty?).select { |f| behavioral?(f) }
  end
end
