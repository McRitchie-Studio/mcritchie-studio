# frozen_string_literal: true

require "test_helper"

# The dream loop on /dreams (docs/agents/modules/dream.md, Act 4), against the
# fixture bank (DREAM_BANK_DIR):
#   [component] the KPI strip, a card's grade and heat marks, the swap panel;
#   [integration] Alex's one-click Retire and Approve swap, and who is refused.
class DreamsLoopPageTest < ActionDispatch::IntegrationTest
  BANK = Rails.root.join("test/fixtures/dreams").to_s
  APPROVED = { dream_home: "carl", dream_slug: "money-review-reads-the-ledger" }.freeze

  setup do
    @previous_bank = ENV["DREAM_BANK_DIR"]
    ENV["DREAM_BANK_DIR"] = BANK
    log_in_as(users(:alex))
  end

  teardown { ENV["DREAM_BANK_DIR"] = @previous_bank }

  def fire(slug, session:, at: 1.hour.ago)
    AgentAction.create!(session_id: session, kind: DreamHeat::KIND, event_slug: slug, summary: "decided", occurred_at: at,
                        outcome: "ok")
  end

  test "[component] the KPI strip renders its four tiles, empty before any data" do
    get dreams_path

    assert_select "[data-test='dream-kpis']" do
      %w[fire-rate mean-grade swaps-per-week approval-latency].each do |key|
        assert_select "[data-test='dream-kpi-#{key}'] [data-test='dream-kpi-value']", 1, key
      end
      assert_select "[data-test='dream-kpi-mean-grade'] [data-test='dream-kpi-value']", text: "—"
    end
    assert_select "[data-test='dream-swaps']", 0, "no panel without an open swap"
  end

  test "[component] a graded, fired dream shows its mean grade and a heat level" do
    5.times { |n| fire("list-the-candidates", session: "s#{n}") }
    DreamGrade.record!(session_id: "s0", dream_slug: "list-the-candidates", score: 2, decision: "listed both")
    DreamGrade.record!(session_id: "s1", dream_slug: "list-the-candidates", score: 1, decision: "listed three")

    get dreams_path

    assert_select "[data-dream='list-the-candidates'][data-heat='hot']" do
      assert_select "[data-test='dream-grade']", text: "graded 1.5 (2)"
      assert_select "[data-test='dream-fire-count']", text: "5 fired"
    end
    assert_select "[data-dream='list-the-candidates'] [data-test='dream-loop-stats']", text: /Fired 5 times · graded 1.5 \(2\)/
    assert_select "[data-dream='report-what-you-verified'][data-heat='cold'] [data-test='dream-grade']", 0
    assert_select "[data-dream='report-what-you-verified'] [data-test='dream-loop-stats']",
                  text: /cold\s+Fired 0 times · not graded yet/
    assert_select "[data-test='dream-kpi-mean-grade'] [data-test='dream-kpi-value']", text: "1.5 / 2"
  end

  test "[integration] Alex retires an approved dream in one click; the card then reads retiring" do
    get dreams_path
    assert_select "[data-dream='money-review-reads-the-ledger'] [data-test='dream-retire']", 1
    assert_select "[data-dream='proposed-money-idea'] [data-test='dream-retire']", 0

    assert_difference -> { DreamRetirement.count }, 1 do
      post dream_retirements_path, params: APPROVED.merge(status: "approved")
    end
    assert_redirected_to dreams_path(status: "approved", anchor: "dream-money-review-reads-the-ledger")
    assert_equal 303, response.status

    follow_redirect!
    assert_select "[data-dream='money-review-reads-the-ledger']" do
      assert_select "[data-test='dream-retiring-badge']", text: "Retired, drops after the next release"
      assert_select "[data-test='dream-retire']", 0
      assert_select "[data-test='dream-retirement-note']", text: %r{bin/dream apply-approvals}
    end
    assert_no_difference -> { DreamRetirement.count } do
      post dream_retirements_path, params: APPROVED
    end
  end

  test "[integration] a proposed, unknown or forged dream is not retired" do
    [ { dream_home: "pokemon", dream_slug: "proposed-money-idea" }, { dream_home: "carl", dream_slug: "nope" },
      { dream_home: "pokemon", dream_slug: "money-review-reads-the-ledger" }, {} ].each do |params|
      assert_no_difference -> { DreamRetirement.count }, params.inspect do
        post dream_retirements_path, params: params
      end
      assert_match(/\ANot retired: /, flash[:alert])
    end
  end

  test "[integration] another admin, a viewer and a visitor cannot retire, and see no button" do
    reset!
    seat = User.create!(email: "admin@mcritchie.studio", name: "Admin McRitchie", role: "admin")
    log_in_as(seat)
    get dreams_path
    assert_select "[data-test='dream-retire']", 0
    assert_no_difference(-> { DreamRetirement.count }) { post dream_retirements_path, params: APPROVED }
    assert_equal "Not retired: only Alex retires dreams.", flash[:alert]

    reset!
    log_in_as(users(:viewer))
    assert_no_difference(-> { DreamRetirement.count }) { post dream_retirements_path, params: APPROVED }
    assert_not_equal dreams_path, URI(response.location).path

    reset!
    assert_no_difference(-> { DreamRetirement.count }) { post dream_retirements_path, params: APPROVED }
    assert_response :redirect
  end

  test "[integration] the swap panel shows an open swap, and Alex's one click approves the in and retires the out" do
    swap = DreamSwap.create!(session_id: "wrap-1", reason: "Lowest grade, a sharper habit in", layer: "soul/pokemon",
                             in_home: "pokemon", in_slug: "proposed-money-idea",
                             out_home: "pokemon", out_slug: "untagged-habit")
    DreamSwap.create!(session_id: "wrap-2", reason: "nothing earned it")

    get dreams_path
    assert_select "[data-test='dream-swaps'] [data-test='dream-swap']", 1
    assert_select "[data-swap='#{swap.id}'][data-kind='swap']" do
      assert_select "[data-test='dream-swap-in']", text: /In/
      assert_select "[data-test='dream-swap-out']", text: /Out/
      assert_select "[data-test='dream-swap-approve']", 1
    end

    post dream_swap_approval_path(swap)
    assert_redirected_to dreams_path(anchor: "dream-swaps")

    assert swap.reload.approved_at
    assert DreamApproval.exists?(dream_home: "pokemon", dream_slug: "proposed-money-idea")
    assert DreamRetirement.exists?(dream_home: "pokemon", dream_slug: "untagged-habit", dream_swap_id: swap.id)
    follow_redirect!
    assert_select "[data-test='dream-swaps']", 0
    assert_select "[data-dream='untagged-habit'] [data-test='dream-retiring-badge']", 1
  end

  test "[integration] a swap whose in has not shipped is refused, and another admin cannot approve one" do
    unshipped = DreamSwap.create!(session_id: "wrap-1", reason: "r", layer: "soul/pokemon",
                                  in_home: "pokemon", in_slug: "still-in-a-desk")
    get dreams_path
    assert_select "[data-swap='#{unshipped.id}'] [data-test='dream-swap-approve']", 0

    post dream_swap_approval_path(unshipped)
    assert_match(/has not shipped yet/, flash[:alert])
    assert_nil unshipped.reload.approved_at

    reset!
    log_in_as(User.create!(email: "admin@mcritchie.studio", name: "Admin McRitchie", role: "admin"))
    shipped = DreamSwap.create!(session_id: "wrap-2", reason: "r", layer: "soul/pokemon",
                                in_home: "pokemon", in_slug: "proposed-money-idea")
    post dream_swap_approval_path(shipped)
    assert_equal "Swap not approved: only Alex approves swaps.", flash[:alert]
    assert_nil shipped.reload.approved_at
    assert_equal 0, DreamApproval.count
  end
end
