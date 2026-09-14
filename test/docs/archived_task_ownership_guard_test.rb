# frozen_string_literal: true

require "test_helper"

# A TASK SLUG IS BOARD STATE. PROSE CANNOT TRACK IT.
#
# Eight sites across six hub files named `/tasks/turf-vault-needs-ci` as the LIVE
# owner of turf-vault's missing local cert lane. That task had shipped the repo's
# first CI WORKFLOW — a different thing — and been ARCHIVED. So the gap had no
# owner, and every reader who followed the pointer landed on a terminal task for a
# decision nobody held. Found 2026-09-14; the gap itself is now closed by declaring
# the lane (config/release_repos.yml), and this guard stops the pattern returning.
#
# WHAT IT FORBIDS, precisely: an OWNERSHIP CLAIM attached to a `/tasks/<slug>`
# citation — "…, which owns declaring one", "owned by /tasks/x", "/tasks/x owns it".
# Such a sentence asserts something about the BOARD, which changes without touching
# this repo, so it is false the moment the task is archived and reads exactly like
# the truth forever after.
#
# WHAT IT ALLOWS, deliberately: HISTORICAL citations. "/tasks/turf-vault-needs-ci
# gave the repo its first CI, which unblocked …" is a record of something that
# happened, and archiving the task does not make it false. Two such lines live in
# config/release_repos.yml and are correct; a guard that removed them would trade a
# stale claim for a lost one. The distinction is exactly the ownership verb.
#
# THE REMEDY when this fails: name the MECHANISM instead of the task — the file, the
# key, the script the reader can open in their own checkout. If a live task really
# does own an open decision, say so without the ownership verb ("tracked in
# /tasks/x") and accept that the sentence may outlive the task, or put the pointer
# where board state is actually read.
#
# ITS LIMIT, STATED PLAINLY: this cannot tell a live task from an archived one. The
# board is not reachable from the test environment (no credential, no network, and
# the test database holds fixtures rather than production tasks), so a check keyed on
# real task state is not available here. It forbids the CLAIM SHAPE instead, which is
# the durable half — an ownership claim goes stale on its own schedule whether or not
# anyone notices, so the fix is to not make it in prose at all.
class ArchivedTaskOwnershipGuardTest < ActiveSupport::TestCase
  CITATION = %r{/tasks/([a-z0-9][a-z0-9-]*)}
  OWNERSHIP = /\bowns\b|\bowned by\b|\bowner of\b/i
  TRAILING_OWNERSHIP = /\b(?:owned by|owner of)\s*\z/i

  # Where a pointer like this actually hurts: prose every agent reads at session
  # start (the two GENERATED root docs among it), the gate modules, and the scripts
  # that print messages on screen mid-run.
  SCANNED_GLOBS = [
    "docs/**/*.md",
    "config/*.yml",
    "bin/*"
  ].freeze

  # The floor exists so a glob that silently stops matching cannot pass as a clean
  # scan. Measured 2026-09-14: 185 citations across 281 files.
  MINIMUM_CITATIONS = 120

  def test_no_hub_document_or_script_claims_a_task_OWNS_a_live_gap
    offenders = []
    scanned = 0

    scan_files.each do |path|
      body = read_text(path)
      next unless body

      body.to_enum(:scan, CITATION).each do
        m = Regexp.last_match
        scanned += 1
        next unless ownership_claim?(body, m)

        offenders << "#{relative(path)} — /tasks/#{m[1]}: #{claim_window(body, m).strip.inspect}"
      end
    end

    assert_operator scanned, :>=, MINIMUM_CITATIONS,
                    "only #{scanned} task citations were scanned (expected >= #{MINIMUM_CITATIONS}). " \
                    "The globs have stopped matching, so a clean result here proves nothing."

    assert_empty offenders, <<~MSG
      A hub document or script claims a TASK owns a live gap:

      #{offenders.join("\n      ")}

      A task's state is board data this repo cannot track, so the claim is false the
      moment the task is archived — which is exactly what happened to
      /tasks/turf-vault-needs-ci across eight sites. Name the MECHANISM instead: the
      file, the key, or the script the reader can open in their own checkout.
      A purely HISTORICAL citation ("/tasks/x gave the repo its first CI") is fine
      and is what this guard deliberately leaves alone.
    MSG
  end

  # THE DETECTOR MUST BITE, and on a fixed tree nothing proves that. These are the
  # VERBATIM sentences from the six ownership sites as they stood on `main` at
  # 2026-09-14, before this task removed them. If the scan above ever goes quiet
  # because the pattern rotted rather than because the tree is clean, these fail.
  HISTORICAL_OFFENDERS = [
    "with its own test surface, owned by /tasks/turf-vault-needs-ci. An inert",
    "# answer. /tasks/turf-vault-needs-ci owns it.",
    'way a gem declares its test lane — see /tasks/turf-vault-needs-ci, which owns that decision. ',
    "`/tasks/turf-vault-needs-ci`, which owns declaring one. That is a registry gap, not an",
    "one, and `/tasks/turf-vault-needs-ci` owns what that lane should be. The"
  ].freeze

  def test_the_detector_flags_every_ownership_site_this_task_removed
    HISTORICAL_OFFENDERS.each do |sentence|
      m = CITATION.match(sentence)
      refute_nil m, "fixture carries no task citation: #{sentence.inspect}"

      assert ownership_claim?(sentence, m),
             "the detector no longer flags a sentence that IS the defect — it would have " \
             "passed the pre-fix tree: #{sentence.inspect}"
    end
  end

  # THE OTHER HALF, and the one a blunter guard fails: the historical citations must
  # NOT be flagged. Verbatim from config/release_repos.yml, where they are accurate
  # and must survive.
  HISTORICAL_KEEPERS = [
    "# /tasks/turf-vault-needs-ci gave the repo its first CI, which unblocked\n" \
    "# /tasks/mainnet-launch-doc-vault-rename after FOUR held sweeps — and the",
    "Tripwire for the defect in /tasks/duplicate-doc-blocks-archive: a doc tracked"
  ].freeze

  def test_the_detector_leaves_historical_citations_alone
    HISTORICAL_KEEPERS.each do |sentence|
      sentence.to_enum(:scan, CITATION).each do
        m = Regexp.last_match
        refute ownership_claim?(sentence, m),
               "a historical citation was flagged as an ownership claim; the guard would force the " \
               "deletion of an accurate record: #{sentence.inspect}"
      end
    end
  end

  private

  def ownership_claim?(body, match)
    OWNERSHIP.match?(claim_window(body, match)) ||
      TRAILING_OWNERSHIP.match?(lead_window(body, match))
  end

  # The rest of the SENTENCE the citation sits in. Cutting at the sentence boundary
  # is what keeps this precise: a fixed-width window ran past the end of the
  # paragraph and flagged docs/topics/frontend.md, whose next heading happens to read
  # "Who owns which claim:" — a real sentence about test claims, not about the task.
  def claim_window(body, match)
    normalize(body[match.end(0), 220].to_s).split(/(?<=\.)\s/, 2).first.to_s
  end

  def lead_window(body, match)
    normalize(body[[match.begin(0) - 45, 0].max...match.begin(0)].to_s)
  end

  # Fold comment leaders and wrapped lines away, so a claim split across two `#`
  # lines reads as one sentence — which is how five of the six sites were written.
  def normalize(text)
    text.gsub(/[\r\n]+[ \t]*(?:[#*]|\/\/)?[ \t]*/, " ")
  end

  def scan_files
    SCANNED_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob)] }
                 .reject { |p| p.include?("/docs/agents/archive/") }
                 .select { |p| File.file?(p) }
                 .sort
  end

  def read_text(path)
    body = File.read(path, encoding: "UTF-8")
    body.valid_encoding? ? body : nil
  rescue ArgumentError, Errno::ENOENT
    nil
  end

  def relative(path) = Pathname.new(path).relative_path_from(Rails.root).to_s
end
