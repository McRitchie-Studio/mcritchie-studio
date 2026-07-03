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
      a = AtomicAction.capture(session_id: "gen-#{slug.object_id}", kind: "edit", outcome: "ok",
                               task_slug: overrides.delete(:task_slug))
      g = ActionGrade.create!({ atomic_action: a, grader: "alex", slug: slug, disposition: "good" }.merge(overrides))
      g.bank!
      g
    end

    test "[integration] generate! writes only banked lessons to the target path" do
      banked(slug: "bank this good lesson", task_slug: "feat-y")
      banked(slug: "avoid this bad pattern", disposition: "not")
      ActionGrade.create!(atomic_action: AtomicAction.capture(session_id: "gen-unbanked", kind: "read"),
                          grader: "alex", slug: "not banked at all", disposition: "good") # unbanked → excluded

      Dir.mktmpdir do |dir|
        path = File.join(dir, "insights.md")
        written = DocGenerator.generate!(path: path, at: AT)

        assert_equal path, written.to_s
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
  end
end
