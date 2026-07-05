module Insights
  # Generates the tracked "distilled lessons" doc FROM the Insight Bank
  # (ActionGrade.banked), making the bank the CANONICAL store and the doc a
  # derived artifact (the same generated-file pattern as the AGENTS.md adapters).
  # This retires the hand-edited docs/agents/shared/MEMORY.md, which drifted stale.
  #
  #   Insights::DocGenerator.render(insights:, generated_at:)  # pure → markdown
  #   Insights::DocGenerator.generate!(at: Time.current)       # bank → write the doc
  #
  # `render` is PURE (hashes in, markdown out — no ActiveRecord, deterministic given
  # `generated_at`) so it unit-tests without the DB. `generate!` reads the bank,
  # normalizes each grade to a hash, and writes the file.
  module DocGenerator
    module_function

    # Where the generated lessons doc lives (tracked, distributed with the agent docs).
    def default_path
      Rails.root.join("docs/agents/shared/insights.md")
    end

    # Read ActionGrade.banked, render, and write the doc. Returns the COUNT of
    # insights written — the same number the doc header shows — so callers (the rake
    # task) never report a count from a different source than the doc.
    def generate!(path: default_path, at: Time.current)
      insights = banked_insights
      File.write(path, render(insights: insights, generated_at: at))
      insights.size
    end

    # The banked grades as render-ready hashes: newest curation first, blank-slug
    # rows dropped (the same set render shows, so counts can't diverge).
    def banked_insights
      ActionGrade.banked
                 .includes(:agent_action, :agent_activity)
                 .order(updated_at: :desc)
                 .map { |g| normalize(g) }
                 .reject { |i| i[:slug].to_s.strip.empty? }
    end

    # Normalize one banked ActionGrade to the render hash. Provenance is read inline
    # from whichever source is set (no dependency on any provenance helper).
    def normalize(grade)
      {
        slug: grade.slug,
        disposition: grade.disposition,
        long_form: grade.long_form,
        grader: grade.grader,
        task_slug: (grade.agent_action&.task_slug || grade.agent_activity&.task_slug)
      }
    end

    # Pure: the markdown for the lessons doc. `insights` is an array of hashes
    # (slug, disposition, long_form, grader, task_slug — string OR symbol keys).
    def render(insights:, generated_at:)
      rows = Array(insights).map { |i| i.transform_keys(&:to_sym) }.reject { |i| i[:slug].to_s.strip.empty? }
      good = rows.select { |i| i[:disposition].to_s != "not" }
      avoid = rows.select { |i| i[:disposition].to_s == "not" }

      out = +header(generated_at, rows.size)
      if rows.empty?
        out << "\n_No insights banked yet. Grade resolved activities and `--bank` the ones worth carrying\n" \
               "forward (`bin/agent-activity grade <activity-id> --bank`), then regenerate with " \
               "`bin/rails insights:doc`._\n"
        return out
      end

      out << section("✓ Do — patterns that worked", good)
      out << section("✗ Avoid — patterns that hurt", avoid)
      out
    end

    # ── private-ish render helpers ────────────────────────────────────────────

    def header(generated_at, count)
      stamp = generated_at.respond_to?(:strftime) ? generated_at.strftime("%Y-%m-%d") : generated_at.to_s
      <<~HEAD
        <!-- GENERATED FROM THE INSIGHT BANK — DO NOT EDIT BY HAND.
             The Insight Bank (ActionGrade.banked) is canonical; this doc is derived.
             Curate lessons: `bin/agent-activity grade <activity-id> --disposition good|not --slug "…" --bank`
             Regenerate:     `bin/rails insights:doc` (reads the bank on the board) -->

        # Insight Bank — distilled agent lessons

        _Generated #{stamp} from #{count} banked #{count == 1 ? 'insight' : 'insights'}. Do not hand-edit —
        curate the bank and regenerate. A fresh session **will** load these via the planned
        `bin/session-insights` SessionStart loader once it lands._
      HEAD
    end

    def section(title, rows)
      return "" if rows.empty?

      body = rows.map { |i| bullet(i) }.join("\n")
      "\n## #{title}\n\n#{body}\n"
    end

    def bullet(insight)
      line = +"- **#{insight[:slug]}**"
      line << " — #{insight[:long_form].to_s.strip}" if present?(insight[:long_form])
      meta = [insight[:task_slug], grader_label(insight[:grader])].compact.reject { |m| m.to_s.strip.empty? }
      line << "  _(#{meta.join(' · ')})_" unless meta.empty?
      line
    end

    def grader_label(grader)
      case grader.to_s
      when "mcr" then "McRitchie audit"
      when "alex" then "Alex"
      end
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
