require "test_helper"
require "fugit"

module Insights
  # The staleness detector for docs/agents/shared/insights.md.
  #
  # WHAT CI CAN PROVE HERE, AND WHAT IT CANNOT — stated first, because the answer
  # shaped every test below.
  #
  # It CANNOT assert that the tracked doc's recorded count equals the live bank.
  # CI's database is the TEST database and it holds no bank; a desk worktree's is an
  # empty DEV database. Asserting equality against either would fail on every PR or
  # pass vacuously, and "regenerate to make CI green" would write a confident "0
  # banked insights" — trading a stale artefact for a FALSE one. That comparison is
  # only meaningful where both halves exist, which is a dyno on the board, and it
  # runs there on a schedule (InsightsDocFreshnessJob).
  #
  # What CI CAN do is keep that detector honest, which is what these tests are:
  #
  #   (1) The header stays MACHINE-READABLE. The detector's entire grip on the
  #       artefact is one generated line. Reword it and the detector goes blind
  #       while every test still passes — so the parser is round-tripped against
  #       the generator's own output, and a reword fails here instead.
  #   (2) The SCHEDULE stays REGISTERED. The deliverable of this task is the
  #       schedule, not the one-off file. Delete the recurring entry and the
  #       artefact is silent again — so the registration is read out of
  #       config/recurring.yml as a state fact, the same way the header guard one
  #       file over reads the loader's state before judging its claim.
  #   (3) The VERDICTS are right, exercised with injected values so they need no
  #       bank at all.
  class DocFreshnessTest < ActiveSupport::TestCase
    AT = Time.utc(2026, 9, 9, 12, 0, 0)
    ON = Date.new(2026, 9, 9)

    # ── (1) the header stays machine-readable ────────────────────────────────
    #
    # Round-tripped against DocGenerator.render rather than against a copied string:
    # a fixture of the header would keep agreeing with itself after the generator
    # moved on, which is the exact failure mode this pair exists to prevent.

    test "[unit] the parser recovers what the generator wrote, for an empty bank" do
      recorded = DocFreshness.parse(DocGenerator.render(insights: [], generated_at: AT))

      assert recorded, "the generator's own empty-bank header must stay parseable"
      assert_equal 0, recorded[:count]
      assert_equal ON, recorded[:generated_on]
    end

    test "[unit] the parser recovers what the generator wrote, singular and plural" do
      one = DocGenerator.render(insights: [{ slug: "a lesson", disposition: "good" }], generated_at: AT)
      many = DocGenerator.render(
        insights: [{ slug: "a lesson", disposition: "good" }, { slug: "another", disposition: "not" }],
        generated_at: AT
      )

      [one, many].each do |markdown|
        assert DocFreshness.parse(markdown),
               "DocGenerator's header is no longer readable by DocFreshness::HEADER. Rewording " \
               "the generated header BLINDS the scheduled staleness detector — it would report " \
               "every doc unparseable — so the parser has to move with it."
      end

      assert_equal 1, DocFreshness.parse(one)[:count], "a one-insight header reads '1 banked insight'"
      assert_equal 2, DocFreshness.parse(many)[:count]
      assert_equal ON, DocFreshness.parse(many)[:generated_on]
    end

    test "[unit] a header the detector cannot read is a finding, never a pass" do
      assert_nil DocFreshness.parse("# Insight Bank\n\nno generated header at all\n")
      assert_nil DocFreshness.parse(""), "an empty file cannot be certified fresh"
    end

    # ── (2) the schedule stays registered ────────────────────────────────────
    #
    # THE STATE half. A detector that is not scheduled detects nothing, so this is
    # read before any claim about detectability is trusted.

    def production_schedule
      YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production", {})
    end

    test "[integration] the freshness detector is registered as a production recurring job" do
      entry = production_schedule.values.find { |e| e["class"] == "InsightsDocFreshnessJob" }

      assert entry,
             "config/recurring.yml no longer schedules InsightsDocFreshnessJob in production. " \
             "The board is the only environment that can compare the tracked doc against the live " \
             "bank, so without this entry a stale insights.md is silent again — which is the defect " \
             "/tasks/insights-doc-never-regenerated fixed. Restore the schedule."

      assert_nothing_raised do
        Object.const_get(entry["class"])
      end
      assert Fugit.parse(entry["schedule"]),
             "the schedule #{entry['schedule'].inspect} is not a cron Solid Queue can parse, " \
             "so the detector would never fire"
    end

    # ── (3) the verdicts ─────────────────────────────────────────────────────

    def doc(count:, generated_on: ON)
      rows = Array.new(count) { |i| { slug: "lesson #{i}", disposition: "good" } }
      DocGenerator.render(insights: rows, generated_at: generated_on.in_time_zone)
    end

    def check_markdown(markdown, live_count:, last_curated_at: nil)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "insights.md")
        File.write(path, markdown)
        return DocFreshness.check(path: path, live_count: live_count, last_curated_at: last_curated_at)
      end
    end

    test "[unit] a doc whose count matches an uncurated-since bank is fresh" do
      result = check_markdown(doc(count: 5), live_count: 5,
                              last_curated_at: (ON - 3).in_time_zone)

      assert_predicate result, :fresh?
      assert_equal :fresh, result.status
      assert_equal 5, result.recorded_count
    end

    test "[unit] a count that disagrees with the bank is stale and names both numbers" do
      result = check_markdown(doc(count: 0), live_count: 5, last_curated_at: (ON - 3).in_time_zone)

      assert_predicate result, :stale?
      assert_equal :count_drift, result.status
      assert_match(/records 0 banked insights/, result.message)
      assert_match(/bank holds 5/, result.message)
      assert_match(/BOARD's database/, result.message,
                   "the remedy must warn against regenerating from a desk, which is the trap")
    end

    # The case a count check alone cannot see: a lesson edited in place leaves the
    # count untouched while the doc's copy of its text goes stale.
    test "[unit] a bank curated after the doc was generated is stale even at an equal count" do
      result = check_markdown(doc(count: 5), live_count: 5,
                              last_curated_at: (ON + 2).in_time_zone)

      assert_predicate result, :stale?
      assert_equal :content_drift, result.status
      assert_match(/count still matches/, result.message)
    end

    # The freshness bound is CAUSAL, not calendar: an old doc that nobody has
    # out-curated is correct, and flagging it would train readers to ignore the
    # signal.
    test "[unit] an old doc is fresh while nothing has been curated since" do
      old = ON - 400
      result = check_markdown(doc(count: 5, generated_on: old), live_count: 5,
                              last_curated_at: (old - 1).in_time_zone)

      assert_predicate result, :fresh?, "age alone is not staleness"
    end

    test "[unit] same-day curation is inside the artefact's own date resolution" do
      result = check_markdown(doc(count: 5), live_count: 5,
                              last_curated_at: ON.in_time_zone + 23.hours)

      assert_predicate result, :fresh?,
                       "the header records a date, not a timestamp; a same-day edit that " \
                       "changed the count is caught by the count check instead"
    end

    test "[unit] an unreadable header reports the detector is blind, not that all is well" do
      result = check_markdown("# Insight Bank\n\nhand-written, no header\n", live_count: 5)

      assert_predicate result, :stale?
      assert_equal :unparseable, result.status
      assert_match(/machine-readable/, result.message)
    end

    test "[unit] a missing doc is stale" do
      result = DocFreshness.check(path: Rails.root.join("tmp/does-not-exist-insights.md"), live_count: 0)

      assert_predicate result, :stale?
      assert_equal :missing, result.status
    end

    # ── the check reads the real bank when not given one ─────────────────────

    def banked(slug:, **overrides)
      action = AgentAction.capture(session_id: "fresh-#{slug.object_id}", kind: "edit", outcome: "ok")
      grade = ActionGrade.create!({ agent_action: action, grader: "alex", slug: slug,
                                    disposition: "good" }.merge(overrides))
      grade.bank!
      grade
    end

    test "[integration] check reads ActionGrade.banked when no count is injected" do
      banked(slug: "a banked lesson")
      banked(slug: "a second banked lesson")

      Dir.mktmpdir do |dir|
        path = File.join(dir, "insights.md")
        DocGenerator.generate!(path: path, at: Time.current)

        result = DocFreshness.check(path: path)

        assert_predicate result, :fresh?, "a doc generated from this bank a moment ago is fresh"
        assert_equal 2, result.live_count
        assert_equal 2, result.recorded_count
      end
    end

    test "[integration] check catches a doc the bank has moved past" do
      banked(slug: "a banked lesson")

      Dir.mktmpdir do |dir|
        path = File.join(dir, "insights.md")
        DocGenerator.generate!(path: path, at: Time.current)
        banked(slug: "banked after the doc was written")

        result = DocFreshness.check(path: path)

        assert_predicate result, :stale?
        assert_equal :count_drift, result.status
        assert_equal 1, result.recorded_count
        assert_equal 2, result.live_count
      end
    end

    # ── the tracked artefact itself ──────────────────────────────────────────

    test "[integration] the tracked insights doc is readable by the detector" do
      tracked = DocGenerator.default_path
      assert File.exist?(tracked), "#{tracked} is tracked and must exist"

      recorded = DocFreshness.parse(File.read(tracked))

      assert recorded,
             "docs/agents/shared/insights.md no longer carries the generated header the detector " \
             "reads, so the scheduled job could not tell fresh from stale. Regenerate it with " \
             "`bin/rails insights:doc` against the board."
      assert_kind_of Date, recorded[:generated_on]

      # Deliberately NOT `assert_equal live_bank_count, recorded[:count]`. See the
      # header comment: CI's bank is empty, so that assertion could only be
      # satisfied by writing a false doc. The count's agreement with the bank is
      # the scheduled job's verdict, on the board, where the bank is real.
      assert_operator recorded[:count], :>=, 0
    end
  end
end
