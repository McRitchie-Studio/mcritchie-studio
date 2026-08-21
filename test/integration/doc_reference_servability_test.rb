# frozen_string_literal: true

require "test_helper"
require_relative "../support/doc_reference_scanner"

# THE GUARD. Every reference a live agent doc makes must be reachable through the
# route that serves agent docs.
#
# WHAT WENT WRONG WITHOUT IT. Nine role.md files carried `![<Soul> Avatar](avatar.png)`
# beside a committed docs/agents/agents/<slug>/avatar.png — ten files, 5.75MB. Every
# one of those nine embeds rendered broken, from the day it landed:
# DocsController#show builds `DOCS_ROOT/<path>.md` and reads nothing else, and its
# path guard `/\A[a-z0-9_\-\/]+\z/i` rejects the dot before that branch is even
# reached, so the route cannot serve an image at ALL. docs/ is copied into EVERY
# worktree, so the cost was 5.75MB per desk to render nine broken images.
#
# Three separate tests already touched those files and none of them could see it:
# agent_file_links_test asserted the file TREE does not link them (true, and the
# reason the tree is right), agent_portrait_assets_test guards public/agents (a
# different directory), and agent_avatar_generator_test asserted the generator WROTE
# them. Nobody had asked the only question that mattered — whether a doc's own
# references resolve through the docs route. This asks it, for all of them.
#
# THE ROUTE IS THE AUTHORITY HERE. The scanner says what a doc points at; the verdict
# comes from a real GET. Re-deriving "servable" from the controller's regex would only
# prove this test agrees with a copy of the rule, which is what let the original defect
# through — role.md's author and the route never compared notes.
class DocReferenceServabilityTest < ActionDispatch::IntegrationTest
  DOCS_ROOT = Rails.root.join("docs", "agents")

  # Frozen audit snapshots. AGENTS.md: historical snapshots stay as written, and
  # several cross-reference docs that were archived or renamed after the snapshot was
  # taken. Re-pointing those links would falsify the record of what was true that day.
  SKIP_PREFIXES = ["archive/"].freeze

  test "[integration] every reference in a live doc is servable by the docs route" do
    references = DocReferenceScanner.scan(DOCS_ROOT, skip: SKIP_PREFIXES)

    # The floor, not a nicety: an extractor that returned [] would make the assertion
    # below vacuously true on a corpus of nothing but broken links.
    assert_operator references.size, :>=, 250,
                    "only #{references.size} references found in docs/agents — the scanner has " \
                    "gone blind, and the assertion below would pass while grading nothing"

    verdicts  = {}
    unservable = references.reject do |ref|
      verdicts.fetch(ref[:resolved]) { verdicts[ref[:resolved]] = servable?(ref[:resolved]) }
    end

    assert_empty unservable.map { |ref| "#{ref[:source]} → #{ref[:target]}" }.uniq,
                 "these docs reference something GET /docs/<path> will not serve. The docs route " \
                 "serves `<path>.md` under docs/agents and nothing else — no images, and nothing " \
                 "outside that root. Point the reference at a doc, or write the path in backticks " \
                 "instead of as a link."
  end

  # THE PREMISE, pinned. The test above only means something while the route really
  # does refuse an image; if it stopped refusing, that test would keep passing and
  # quietly stop guarding anything. This is also the tripwire for anyone who decides
  # to teach the route to serve assets after all — they must come here and say so.
  test "[integration] the docs route refuses an image path" do
    get "/docs/agents/carl/avatar.png"

    assert_response :not_found,
                    "DocsController#show is markdown-only, and app/views/agents/show.html.erb " \
                    "renders non-markdown tree entries as unlinked text because of it. If you " \
                    "taught the route to serve images, update this test and the file tree together."
  end

  # The other half of the premise: a reference that climbs out of docs/agents is
  # unservable even when the file exists on disk, because the controller rejects "..".
  test "[integration] the docs route refuses a path that escapes the docs root" do
    assert Rails.root.join("docs", "email-delivery.md").file?,
           "fixture assumes docs/email-delivery.md exists but sits OUTSIDE docs/agents"

    get "/docs/../email-delivery.md"

    refute response.successful?,
           "docs/email-delivery.md is real but outside DOCS_ROOT, so the docs route must not serve it"
  end

  # And the positive control — proof the checker can say yes, so an all-red checker
  # cannot masquerade as a clean corpus.
  test "[integration] a real doc is servable through the same check" do
    assert servable?("agents/carl/role.md"),
           "agents/carl/role.md is a real doc; if this is false the servability check is " \
           "broken, not the corpus"
  end

  private

  # Ask the app, not a copy of its rules. Anything short of a 2xx is unservable —
  # including a raise, which is what a path Rack cannot even route produces.
  def servable?(resolved)
    get "/docs/#{resolved}"
    response.successful?
  rescue StandardError
    false
  end
end
