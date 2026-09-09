require "test_helper"

module Insights
  # The generator that makes the Insight Bank canonical: `render` is a pure
  # hashes→markdown function; `generate!` reads ActionGrade.banked and writes the
  # tracked doc.
  class DocGeneratorTest < ActiveSupport::TestCase
    AT = Time.utc(2026, 7, 3, 12, 0, 0)

    # ── [unit] render ──────────────────────────────────────────────────────

    test "[unit] the empty bank renders a header and a friendly empty state" do
      md = DocGenerator.render(insights: [], generated_at: AT)

      assert_includes md, "GENERATED FROM THE INSIGHT BANK"
      assert_includes md, "Generated 2026-07-03 from 0 banked insights"
      assert_includes md, "No insights banked yet"
      refute_includes md, "## ✓ Do", "no sections when there is nothing to show"
    end

    test "[unit] groups good insights under Do and not insights under Avoid" do
      md = DocGenerator.render(
        insights: [
          { slug: "write the failing test first", disposition: "good", long_form: "red before green",
            grader: "alex", task_slug: "feat-x" },
          { slug: "did not check siblings", disposition: "not", grader: "alex" }
        ],
        generated_at: AT
      )

      assert_includes md, "## ✓ Do — patterns that worked"
      assert_includes md, "- **write the failing test first** — red before green  _(feat-x · Alex)_"
      assert_includes md, "## ✗ Avoid — patterns that hurt"
      assert_includes md, "- **did not check siblings**  _(Alex)_"
      assert_includes md, "from 2 banked insights"
    end

    test "[unit] labels a McRitchie audit grade and tolerates string keys" do
      md = DocGenerator.render(
        insights: [{ "slug" => "audited lesson", "disposition" => "good", "grader" => "mcr" }],
        generated_at: AT
      )
      assert_includes md, "- **audited lesson**  _(McRitchie audit)_"
    end

    test "[unit] drops rows without a slug" do
      md = DocGenerator.render(insights: [{ disposition: "good" }, { slug: "  " }], generated_at: AT)
      assert_includes md, "No insights banked yet", "all rows dropped → empty state"
    end

    # ── [integration] generate! reads the bank and writes the doc ────────────

    def banked(slug:, **overrides)
      a = AgentAction.capture(session_id: "gen-#{slug.object_id}", kind: "edit", outcome: "ok",
                               task_slug: overrides.delete(:task_slug))
      g = ActionGrade.create!({ agent_action: a, grader: "alex", slug: slug, disposition: "good" }.merge(overrides))
      g.bank!
      g
    end

    test "[integration] generate! writes only banked lessons to the target path" do
      banked(slug: "bank this good lesson", task_slug: "feat-y")
      banked(slug: "avoid this bad pattern", disposition: "not")
      ActionGrade.create!(agent_action: AgentAction.capture(session_id: "gen-unbanked", kind: "read"),
                          grader: "alex", slug: "not banked at all", disposition: "good") # unbanked → excluded

      Dir.mktmpdir do |dir|
        path = File.join(dir, "insights.md")
        count = DocGenerator.generate!(path: path, at: AT)

        assert_equal 2, count, "generate! returns the count the doc shows (only banked, non-blank)"
        md = File.read(path)
        assert_includes md, "bank this good lesson"
        assert_includes md, "avoid this bad pattern"
        assert_includes md, "feat-y"
        refute_includes md, "not banked at all", "an unbanked grade never reaches the doc"
      end
    end

    test "[integration] default_path is the tracked shared insights doc" do
      assert_equal Rails.root.join("docs/agents/shared/insights.md").to_s, DocGenerator.default_path.to_s
    end

    # ── the header's CLAIM is pinned to the loader's STATE ───────────────────
    #
    # The header called `bin/session-insights` "the planned … SessionStart loader
    # once it lands" long after it had landed, so every generated copy of the doc
    # told its reader a shipped mechanism was still a plan
    # (/tasks/generated-header-says-planned).
    #
    # The guard against that returning is deliberately NOT a grep for the retired
    # sentence. The sentence gets reworded; a guard that only reads the prose it
    # ships alongside proves nothing about the world. These tests read the
    # loader's STATE out of the checkout and hold the header accountable to it.
    #
    # WHAT CAN BE READ HERE, AND WHAT CANNOT — stated plainly, because the answer
    # shaped the guard. Whether the machine running this test has the hook in its
    # ~/.claude/settings.json is NOT assertable: a CI box has no home settings
    # file, so keying on it would make the guard pass vacuously exactly where it
    # matters most. What IS deterministic from the checkout is the pair of facts
    # that make "it has landed" true for every reader of the repo:
    #
    #   (1) bin/session-insights ships EXECUTABLE. The hook invokes it as a bare
    #       path, so the executable bit is load-bearing, not cosmetic.
    #   (2) bin/install-agent-docs registers that path under `hooks.SessionStart`.
    #
    # Fact (2) is already proven END TO END one file over, in
    # test/commands/install_agent_skills_test.rb, which runs the installer into a
    # sandbox and reads the settings.json it wrote back. This guard needs the same
    # fact cheaply and often, so it reads the registration out of the installer
    # instead of re-running it — a narrower read than that test's, and the reason
    # it is recorded here rather than assumed.
    #
    # Both facts go FALSE if the loader is withdrawn, which is what makes this a
    # pin and not a spell-check: withdraw the binary and (1) fails, strip the
    # registration and (2) fails, and either failure lands before the prose
    # assertions — telling whoever withdrew it that the doc's claim is now the
    # thing to revisit.

    LOADER    = "bin/session-insights".freeze
    INSTALLER = "bin/install-agent-docs".freeze

    # Language that would describe the loader as not-yet-real. A VOCABULARY, not
    # the retired sentence, so a reword cannot walk the old claim back in.
    UNSHIPPED_LANGUAGE = [
      /\bplanned\b/i,
      /\bupcoming\b/i,
      /\bforthcoming\b/i,
      /\bpending\b/i,
      /\bonce it lands\b/i,
      /\bwhen it lands\b/i,
      /\bwill land\b/i,
      /\bnot yet\b/i,
      /\bcoming soon\b/i
    ].freeze

    # The generator's OWN prose: everything above the first "## " section. Banked
    # lessons render inside the sections, so a lesson whose text happens to use
    # one of the words above can never trip this.
    def preamble_of(markdown)
      markdown.to_s.split(/^## /).first.to_s
    end

    # THE STATE half. Read it before judging the claim, so a withdrawn loader
    # fails as a state change rather than as a prose complaint.
    def assert_loader_registered
      loader = Rails.root.join(LOADER)
      assert File.executable?(loader),
             "#{LOADER} must ship executable — the SessionStart hook invokes it as a bare path. " \
             "If the loader really was withdrawn, the generated header's claim about it has to be " \
             "revisited in the same pass; that coupling is what this guard exists to enforce."

      installer = Rails.root.join(INSTALLER)
      assert installer.exist?, "#{INSTALLER} is missing; it is what registers the loader"
      source = installer.read

      assert_match(/hooks\.SessionStart/, source,
                   "#{INSTALLER} no longer wires any SessionStart hook")
      assert_includes source, "/#{LOADER}",
                      "#{INSTALLER} no longer registers #{LOADER} as a SessionStart hook, " \
                      "yet the generated header tells every reader that it does"
    end

    # THE CLAIM half. Asserting the header still NAMES the loader keeps the
    # vocabulary check from passing vacuously on a header that dropped the
    # subject entirely.
    def assert_header_matches_loader_state(markdown, source_label)
      preamble = preamble_of(markdown)

      assert_includes preamble, LOADER,
                      "#{source_label}: the header must still name the loader it describes, " \
                      "or there is no claim left to check"
      assert_includes preamble, "SessionStart",
                      "#{source_label}: the header must still say how the loader runs"

      UNSHIPPED_LANGUAGE.each do |pattern|
        refute_match pattern, preamble,
                     "#{source_label}: the header calls #{LOADER} unshipped (/#{pattern.source}/) while " \
                     "#{INSTALLER} registers it as a SessionStart hook and the executable ships. " \
                     "Correct the claim — the loader landed."
      end
    end

    test "[unit] the header describes a live loader, never a planned one" do
      assert_loader_registered

      assert_header_matches_loader_state(
        DocGenerator.render(insights: [], generated_at: AT), "render (empty bank)"
      )
      assert_header_matches_loader_state(
        DocGenerator.render(insights: [{ slug: "a lesson", disposition: "good" }], generated_at: AT),
        "render (populated bank)"
      )
    end

    test "[integration] generate! writes a header that matches the loader's state" do
      banked(slug: "a banked lesson")

      Dir.mktmpdir do |dir|
        path = File.join(dir, "insights.md")
        DocGenerator.generate!(path: path, at: AT)

        assert_loader_registered
        assert_header_matches_loader_state(File.read(path), "generate! output")
      end
    end

    # The half that a generator-only fix leaves undone: correcting `header` does
    # nothing for the copy already committed. This reads the artefact a reader
    # actually opens and applies the same pin, so "fixed the generator, never
    # regenerated" fails here instead of shipping.
    test "[integration] the tracked insights doc carries the corrected header" do
      assert_loader_registered

      tracked = DocGenerator.default_path
      assert File.exist?(tracked), "#{tracked} is tracked and must exist"

      assert_header_matches_loader_state(
        File.read(tracked),
        "docs/agents/shared/insights.md (regenerate with `bin/rails insights:doc`)"
      )
    end
  end
end
