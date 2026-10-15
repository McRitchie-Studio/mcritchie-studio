# frozen_string_literal: true

require "test_helper"
require Rails.root.join("bin/lib/dream_layers").to_s

# [unit] The swap side of the dream loop: a layer's room, its data-ranked out
# candidates and their grace (DreamLoop), a session's one proposal (DreamSwap) and
# Alex's one click on it, and the KPI strip (DreamKpis).
class DreamLoopTest < ActiveSupport::TestCase
  setup { users(:alex).update_column(:slug, "alex-mcritchie-test") }

  def dream(slug, soul: "carl", status: "approved", source: "")
    DreamBank::Dream.new(slug: slug, home: soul || "platform", status: status, question: "#{slug}?", answer: "A.",
                         why: "", tags: soul ? { "soul" => [ soul ] } : {}, source: source, story: "")
  end

  # A soul layer filled to its budget with approved dreams old enough to be past grace.
  def full_layer(soul = "carl")
    Array.new(DreamLayers.budget("soul/#{soul}")) { |n| dream(format("dream-%02d", n), soul: soul) }
  end

  def sessions(count, since: 1.day.ago)
    count.times do |n|
      AgentActivity.create!(session_id: "load-#{n}", category: "Explore", reason_slug: "orient", opened_at: since + n.minutes)
    end
  end

  def fire(slug, at:, session: "fire-session")
    AgentAction.create!(session_id: session, kind: DreamHeat::KIND, event_slug: slug, summary: "d", occurred_at: at,
                        outcome: "ok")
  end

  def grade(slug, score, session:)
    fire(slug, at: 1.hour.ago, session: session)
    DreamGrade.record!(session_id: session, dream_slug: slug, score: score, decision: "the decision")
  end

  test "[unit] a layer's room counts approved dreams, less retiring, plus approving" do
    dreams = full_layer.first(18) + [ dream("waiting", status: "proposed") ]
    loop = DreamLoop.new(dreams)
    assert_equal 2, loop.report("soul/carl").room

    DreamRetirement.record!(dreams.first, users(:alex))
    DreamApproval.record!(dreams.last, users(:alex))
    report = DreamLoop.new(dreams).report("soul/carl")

    assert_equal [ 18, 1, 1, 2 ], [ report.approved, report.retiring, report.approving, report.room ]
    assert_nil DreamLoop.new(dreams).report("nowhere")
  end

  test "[unit] candidates rank by lowest mean grade, then longest since last fire" do
    dreams = [ dream("praised"), dream("panned"), dream("stale"), dream("fresh"), dream("never") ]
    grade("praised", 2, session: "a")
    grade("panned", 0, session: "b")
    fire("stale", at: 20.days.ago)
    fire("fresh", at: 1.hour.ago)

    ranked = DreamLoop.new(dreams).report("soul/carl").eligible.map { |candidate| candidate.dream.slug }

    assert_equal %w[panned never stale fresh praised], ranked,
                 "a 0 grade goes first; ungraded ones count as 1.0, never-fired before stale before fresh"
  end

  test "[unit] a dream in its grace is not eligible; the approval row, else the source date, starts it" do
    sessions(4)
    clicked = dream("clicked")
    DreamApproval.create!(dream_home: "carl", dream_slug: "clicked", approved_at: 2.days.ago)
    chat = dream("chat", source: "#{3.days.ago.to_date.iso8601} · some task")
    ancient = dream("ancient", source: "no date here")

    report = DreamLoop.new([ clicked, chat, ancient ]).report("soul/carl")
    by_slug = report.candidates.index_by { |candidate| candidate.dream.slug }

    assert by_slug["clicked"].in_grace
    assert_equal 4, by_slug["clicked"].sessions_since
    assert by_slug["chat"].in_grace
    assert_not by_slug["ancient"].in_grace, "a dream with no approval time predates the loop"
    assert_equal [ "ancient" ], report.eligible.map { |candidate| candidate.dream.slug }

    sessions(DreamLoop::GRACE_SESSIONS, since: 1.hour.ago)
    assert_equal 3, DreamLoop.new([ clicked, chat, ancient ]).report("soul/carl").eligible.size
  end

  test "[unit] propose! records an add while the layer has room, and refuses an out there" do
    dreams = full_layer.first(3)
    swap = DreamSwap.propose!(session_id: "s1", reason: "Captured a review habit", in_key: "carl/new-habit",
                              layer: "soul/carl", dreams: dreams)

    assert_equal "add", swap.kind
    assert_equal "carl/new-habit", swap.in_key
    error = assert_raises(DreamSwap::NotProposable) do
      DreamSwap.propose!(session_id: "s2", reason: "r", in_key: "carl/x", out_key: "carl/dream-00", layer: "soul/carl",
                         dreams: dreams)
    end
    assert_includes error.message, "has room"
  end

  test "[unit] a full layer needs an eligible out" do
    dreams = full_layer
    error = assert_raises(DreamSwap::NotProposable) do
      DreamSwap.propose!(session_id: "s1", reason: "r", in_key: "carl/new", layer: "soul/carl", dreams: dreams)
    end
    assert_includes error.message, "is full (20 of 20)"
    assert_includes error.message, "bin/dream swap-candidates --layer soul/carl"

    DreamApproval.create!(dream_home: "carl", dream_slug: "dream-01", approved_at: 1.hour.ago)
    error = assert_raises(DreamSwap::NotProposable) do
      DreamSwap.propose!(session_id: "s1", reason: "r", in_key: "carl/new", out_key: "carl/dream-01", layer: "soul/carl",
                         dreams: dreams)
    end
    assert_includes error.message, "grace"
    assert_raises(DreamSwap::NotProposable) do
      DreamSwap.propose!(session_id: "s1", reason: "r", in_key: "carl/new", out_key: "xan/dream-00", layer: "soul/carl",
                         dreams: dreams)
    end

    swap = DreamSwap.propose!(session_id: "s1", reason: "Lowest grade", in_key: "carl/new", out_key: "carl/dream-00",
                              layer: "soul/carl", dreams: dreams)
    assert_equal "swap", swap.kind
  end

  test "[unit] no swap is a valid answer, and a session answers once" do
    swap = DreamSwap.propose!(session_id: "s1", reason: "Nothing earned a place", dreams: [])
    assert_equal "none", swap.kind

    error = assert_raises(DreamSwap::NotProposable) do
      DreamSwap.propose!(session_id: "s1", reason: "again", in_key: "carl/x", layer: "soul/carl", dreams: [])
    end
    assert_includes error.message, "already answered"
    assert_raises(DreamSwap::NotProposable) { DreamSwap.propose!(session_id: "s2", reason: " ", dreams: []) }
    assert_raises(DreamSwap::NotProposable) do
      DreamSwap.propose!(session_id: "s3", reason: "r", in_key: "carl/x", layer: "galaxy", dreams: [])
    end
  end

  test "[unit] Alex's one click approves the in and retires the out together; nobody else's does" do
    dreams = full_layer
    swap = DreamSwap.propose!(session_id: "s1", reason: "r", in_key: "carl/new", out_key: "carl/dream-00",
                              layer: "soul/carl", dreams: dreams)
    deployed = dreams + [ dream("new", status: "proposed") ]

    assert_raises(DreamSwap::NotApprovable) { swap.approve!(users(:viewer), deployed) }
    error = assert_raises(DreamSwap::NotApprovable) { swap.approve!(users(:alex), dreams) }
    assert_includes error.message, "has not shipped yet"

    swap.approve!(users(:alex), deployed)

    assert swap.reload.approved_at
    assert DreamApproval.exists?(dream_home: "carl", dream_slug: "new")
    assert_equal swap.id, DreamRetirement.find_by!(dream_home: "carl", dream_slug: "dream-00").dream_swap_id
    assert_raises(DreamSwap::NotApprovable) { swap.approve!(users(:alex), deployed) }
    assert_equal 0, DreamSwap.open.count
  end

  test "[unit] the KPI strip reads fire rate, mean grade, swaps per week and approval latency" do
    sessions(4)
    grade("one", 2, session: "load-0")
    grade("two", 1, session: "load-1")
    DreamSwap.create!(session_id: "w1", reason: "r", in_home: "carl", in_slug: "a", layer: "soul/carl",
                      approved_at: 1.day.ago)
    DreamSwap.create!(session_id: "w2", reason: "nothing earned it")
    proposed = dream("late", source: "#{4.days.ago.to_date.iso8601} · task")
    DreamApproval.create!(dream_home: "carl", dream_slug: "late", approved_at: Time.current)

    kpis = DreamKpis.build([ proposed ])

    assert_equal 2, kpis.fires
    assert_equal 4, kpis.sessions
    assert_in_delta 0.5, kpis.fire_rate
    assert_in_delta 1.5, kpis.mean_grade
    assert_in_delta 0.25, kpis.swaps_per_week
    assert_equal 1, kpis.no_swaps
    assert_equal 1, kpis.latency_count
    assert_in_delta 4.0, kpis.latency_days, 1.0
  end

  test "[unit] the KPI strip is empty, not zero, before any data" do
    kpis = DreamKpis.build([])

    assert_nil kpis.fire_rate
    assert_nil kpis.mean_grade
    assert_nil kpis.latency_days
    assert_in_delta 0.0, kpis.swaps_per_week
  end
end
