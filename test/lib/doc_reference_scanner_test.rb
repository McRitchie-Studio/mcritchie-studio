# frozen_string_literal: true

# Tests for test/support/doc_reference_scanner.rb — the READER half of the doc
# servability guard.
#
#   ruby -Itest test/lib/doc_reference_scanner_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# WHY THE EXTRACTOR GETS ITS OWN TEST. test/integration/doc_reference_servability_test.rb
# grades whatever this returns. A scanner that quietly returned [] would make that
# integration test pass on a corpus full of broken references — a green that tested
# nothing, and the exact failure mode the guard exists to prevent. So the rule ("can
# the route serve it?") is proven against the real route over there, and the extraction
# ("what does this doc reference?") is proven here, against markdown whose answer is
# written down beside it.
require "minitest/autorun"
require_relative "../support/doc_reference_scanner"

class DocReferenceScannerTest < Minitest::Test
  DOCS_ROOT = File.expand_path("../../docs/agents", __dir__)

  # ── [unit] extraction ───────────────────────────────────────────────────────

  def test_unit_finds_a_plain_document_link
    assert_equal ["../modules/heartbeats.md"],
                 DocReferenceScanner.references("See [heartbeats](../modules/heartbeats.md) first.")
  end

  # THE REGRESSION. Nine role.md files embedded exactly this, and the docs route
  # cannot serve it. An extractor that only understood `[text](target)` and skipped
  # the `!` image form would have walked straight past all nine.
  def test_unit_finds_an_image_reference
    assert_equal ["avatar.png"],
                 DocReferenceScanner.references("# Carl\n\n![Carl Avatar](avatar.png)\n"),
                 "the image form is the one that was broken; an extractor blind to `!` " \
                 "would have found nothing to grade"
  end

  def test_unit_ignores_external_and_anchor_targets
    markdown = <<~MD
      [board](https://mcritchie.studio/tasks) and [mail](mailto:a@b.com)
      and [protocol-relative](//example.com/x) and [same page](#the-section)
    MD

    assert_empty DocReferenceScanner.references(markdown)
  end

  def test_unit_drops_the_fragment_but_keeps_the_document
    assert_equal ["../modules/gates/dor.md"],
                 DocReferenceScanner.references("[dor](../modules/gates/dor.md#the-gate-grades-the-tree)")
  end

  # THE FALSE POSITIVE THIS FIXED. modules/memory-maintenance.md and
  # skills/wrap/SKILL.md both spell out the index line format INSIDE backticks:
  # `- [Title](topic_file.md) — one-line summary`. Redcarpet renders that as literal
  # text, so it is not a reference — and grading it as one would have demanded a
  # topic_file.md that was never meant to exist.
  def test_unit_ignores_a_link_inside_an_inline_code_span
    markdown = "Each entry reads `- [Title](topic_file.md) — one-line summary`."

    assert_empty DocReferenceScanner.references(markdown),
                 "a link inside backticks is documentation OF the syntax, not a link"
  end

  def test_unit_ignores_links_inside_a_fenced_block
    markdown = <<~MD
      Real one: [heartbeats](../modules/heartbeats.md)

      ```markdown
      [an example](never-written.md)
      ```
    MD

    assert_equal ["../modules/heartbeats.md"], DocReferenceScanner.references(markdown)
  end

  # A stray opening backtick must cost at most its own line. With /m on the code-span
  # pattern one unbalanced tick would blank the rest of the file, and every reference
  # after it would vanish from the grade silently.
  def test_unit_an_unbalanced_backtick_does_not_swallow_later_references
    markdown = <<~MD
      An unclosed ` tick sits here.
      [still counted](../modules/testing.md)
    MD

    assert_includes DocReferenceScanner.references(markdown), "../modules/testing.md"
  end

  # ── [unit] resolution ───────────────────────────────────────────────────────

  def test_unit_resolves_a_target_against_the_docs_tree
    assert_equal "modules/heartbeats.md",
                 DocReferenceScanner.resolve("agents/carl/HEARTBEAT.md", "../../modules/heartbeats.md")
  end

  def test_unit_a_sibling_target_resolves_beside_its_source
    assert_equal "agents/carl/avatar.png",
                 DocReferenceScanner.resolve("agents/carl/role.md", "avatar.png")
  end

  # DocsController#show refuses any path containing "..", so a reference that climbs
  # out of docs/agents is unservable no matter what sits at the other end. Resolution
  # must SHOW the escape rather than clamp it away.
  def test_unit_an_escape_from_the_docs_root_stays_visible
    resolved = DocReferenceScanner.resolve("agents/turf_monster/soul.md", "../../../topics/nfl-pipeline.md")

    assert_equal "../topics/nfl-pipeline.md", resolved
    assert resolved.start_with?(".."), "an escape must be legible to the caller, not silently clamped"
  end

  # ── [unit] the corpus scan ──────────────────────────────────────────────────

  def test_unit_skip_prefixes_drop_those_documents
    kept    = DocReferenceScanner.scan(DOCS_ROOT, skip: ["archive/"])
    unkept  = DocReferenceScanner.scan(DOCS_ROOT)

    assert_empty kept.select { |ref| ref[:source].start_with?("archive/") }
    assert_operator unkept.size, :>, kept.size,
                    "archive/ holds referencing docs, so skipping it must remove some"
  end

  # THE CONTROL, and the assertion that makes the integration guard mean something.
  # Every fixture above is synthetic and would pass just as happily against a scanner
  # wired to nothing. This one asks the real corpus, so "found nothing" cannot pass.
  def test_unit_the_real_corpus_yields_a_substantial_body_of_references
    refs = DocReferenceScanner.scan(DOCS_ROOT, skip: ["archive/"])

    assert_operator refs.size, :>=, 250,
                    "the live docs cross-reference each other heavily; #{refs.size} means the " \
                    "scanner stopped seeing them, and doc_reference_servability_test would then " \
                    "pass while grading nothing"
    assert refs.all? { |ref| ref[:source].end_with?(".md") && !ref[:resolved].empty? },
           "every reference must carry the doc it came from and where it lands"
  end
end
