# frozen_string_literal: true

require "test_helper"

class Release
  # Release::Flow splits each shipped release into four phases that TILE its time, and
  # leads with the median. Every case here is one way the old stage averages misled:
  # overlapping stages that could not be added up, and a mean made of two outliers.
  class FlowTest < ActiveSupport::TestCase
    setup do
      Release.delete_all
      GateRun.where(subject_type: "release").delete_all
      @t0 = Time.zone.parse("2026-09-18 08:00")
    end

    # THE CORE PROPERTY: the four phases sum to created_at → shipped_at, exactly. The
    # stage columns could not promise that (G3 runs inside Assembled), which is why
    # their averages never added up to Total.
    test "[unit] the four phases tile the release's total" do
      release = shipped(created: 0, assembled: 16, shipped: 26, g3: [1, 16], g4: [20, 26])

      phases = Release::Flow.phases_for(release)

      assert_equal({ "batch" => 60, "qa" => 15 * 60, "hold" => 4 * 60, "ship" => 6 * 60 }, phases)
      assert_equal (release.shipped_at - release.created_at).to_i, phases.values.sum
    end

    # A G3 retried three times was doing QA the whole while. Starting QA at the LATEST
    # attempt would bill the first two to Batch.
    test "[unit] QA and Ship start at the FIRST attempt of their gate" do
      release = shipped(created: 0, assembled: 60, shipped: 90, g3: [10, 20], g4: [70, 90])
      gate(release, "g3_candidate", 30, 58, attempt: 2)
      gate(release, "g4_ship", 80, 90, attempt: 2)

      phases = Release::Flow.phases_for(release.reload)

      assert_equal 10 * 60, phases["batch"], "QA began at the first G3 attempt, minute 10"
      assert_equal 10 * 60, phases["hold"], "Ship began at the first G4 attempt, minute 70"
    end

    # A missing stamp collapses its phase to zero rather than inventing time — and a
    # stamp out of order is clamped, so no phase goes negative.
    test "[unit] missing and out-of-order stamps collapse phases instead of inventing time" do
      no_gates = shipped(created: 0, assembled: nil, shipped: 30)
      phases = Release::Flow.phases_for(no_gates)
      assert_equal({ "batch" => 0, "qa" => 0, "hold" => 0, "ship" => 30 * 60 }, phases,
                   "with nothing between open and ship, the whole span is the ship")

      skewed = shipped(created: 0, assembled: 5, shipped: 20, g3: [12, 14], g4: [3, 20])
      skewed_phases = Release::Flow.phases_for(skewed)
      assert skewed_phases.values.all? { |seconds| seconds >= 0 }, "no phase may go negative: #{skewed_phases}"
      assert_equal 20 * 60, skewed_phases.values.sum
    end

    # A shipped_at stamped BEFORE created_at (clock skew) must not raise out of
    # Comparable#clamp on an inverted range — the card renders on a public page.
    test "[unit] a skewed shipped_at does not raise" do
      release = shipped(created: 10, assembled: nil, shipped: 5)

      assert_equal({ "batch" => 0, "qa" => 0, "hold" => 0, "ship" => 0 }, Release::Flow.phases_for(release))
    end

    # THE HEADLINE IS THE MEDIAN, and the mean is kept beside it so the gap between the
    # two is visible. The window below is production's shape: eight ~1h releases and two
    # that sat open for hours.
    test "[unit] median, mean and the outliers that pull the mean up" do
      totals = [26, 49, 599, 30, 38, 62, 80, 532, 116, 57]
      flow = Release::Flow.new(totals.each_with_index.map { |minutes, i| entry("rel-#{i}", minutes * 60) })

      assert_equal ((57 + 62) / 2.0 * 60).round, flow.median_total, "even count: the mean of the middle two"
      assert_equal (totals.sum * 60 / 10.0).round, flow.mean_total
      assert_equal %w[rel-2 rel-7], flow.outliers.map(&:slug), "only the two past 3x the median"
      assert_equal 116 * 60, flow.scale_seconds, "the sparkline scales to the tallest ORDINARY release"
    end

    test "[unit] an empty window reads as nothing, never as zero" do
      flow = Release::Flow.new([])

      refute flow.any?
      assert_nil flow.median_total
      assert_nil flow.mean_total
      assert_equal [], flow.outliers
      assert_equal 0.0, flow.phase_share("batch")
      assert_equal 1, flow.scale_seconds, "floored, so a render can never divide by zero"
    end

    test "[unit] phase medians and shares read the phases, not the totals" do
      flow = Release::Flow.new([
        entry("a", 600, "batch" => 60, "qa" => 300, "hold" => 60, "ship" => 180),
        entry("b", 3600, "batch" => 3000, "qa" => 360, "hold" => 60, "ship" => 180),
        entry("c", 700, "batch" => 60, "qa" => 420, "hold" => 40, "ship" => 180)
      ])

      assert_equal 60, flow.phase_median("batch"), "the typical batch — not the outlier's 50 minutes"
      assert_equal 360, flow.phase_median("qa")
      assert_in_delta 3120.0 / 4900, flow.phase_share("batch"), 0.0001,
                      "the share DOES include the outlier: that is the distortion made visible"
      assert_equal "batch", flow.entries[1].dominant_phase
    end

    # The read: shipped releases only, newest first, capped, with their mascots.
    test "[integration] recent reads the newest shipped releases with their conductor" do
      Pokemon.find_or_create_by!(slug: "pidgey") { |p| p.name = "Pidgey"; p.dex = 16 }
      older = shipped(created: 0, assembled: 10, shipped: 20, g3: [1, 9], g4: [12, 20])
      newer = shipped(created: 100, assembled: 110, shipped: 130, g3: [101, 109], g4: [115, 130])
      newer.update!(metadata: { "devops" => { "mascot" => "pidgey" } })
      Release.create!(branch: "release", state: "assembling") # active — not in the window

      flow = Release::Flow.recent(limit: 5)

      assert_equal [newer.slug, older.slug], flow.entries.map(&:slug)
      assert_equal "Pidgey", flow.entries.first.mascot&.name
      assert_nil flow.entries.last.mascot
      assert_equal [newer.slug], Release::Flow.recent(limit: 1).entries.map(&:slug)
    end

    private

    # Minutes after @t0 for each stamp; g3/g4 are [start, finish] of a first attempt.
    def shipped(created:, assembled:, shipped:, g3: nil, g4: nil)
      release = Release.create!(branch: "release", state: "shipped",
                                created_at: @t0 + created.minutes,
                                assembling_started_at: @t0 + created.minutes,
                                assembled_at: assembled && @t0 + assembled.minutes,
                                shipped_at: @t0 + shipped.minutes)
      gate(release, "g3_candidate", *g3) if g3
      gate(release, "g4_ship", *g4) if g4
      release.reload
    end

    def gate(release, key, start, finish, attempt: 1)
      GateRun.create!(subject_type: "release", subject_slug: release.slug, key: key, attempt: attempt,
                      started_at: @t0 + start.minutes, finished_at: @t0 + finish.minutes, success: true)
    end

    def entry(slug, total, phases = { "batch" => total, "qa" => 0, "hold" => 0, "ship" => 0 })
      Release::Flow::Entry.new(slug: slug, mascot: nil, shipped_at: @t0, total: total, phases: phases)
    end
  end
end
