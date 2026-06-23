require "test_helper"

# ReviewerSelector picks the two senior reviewers for a submitted PR — by domain
# fit, with a LOGGED random tiebreak, splitting the pair 1 heavy / 1 light, and
# never picking the QA owner (no self-gating). It degrades gracefully when the
# reviewer Agent rows aren't seeded.
class ReviewerSelectorTest < ActiveSupport::TestCase
  # Captures the structured tiebreak log line so the audit trail is assertable.
  class CapturingLogger
    attr_reader :lines

    def initialize
      @lines = []
    end

    def info(msg = nil)
      @lines << (msg || (block_given? ? yield : ""))
    end
  end

  def task_for(shape:, risks: [], repos: [])
    Task.create!(title: "reviewer selection sample task", stage: "submitted",
                 metadata: { "devops" => { "shape" => shape, "risk_tags" => risks, "repositories" => repos } })
  end

  def seed_agent(name, domains: nil, review_weight: nil)
    meta = {}
    meta["domains"] = domains unless domains.nil?
    meta["review_weight"] = review_weight unless review_weight.nil?
    Agent.create!(name: name, slug: name.parameterize, metadata: meta)
  end

  def slugs(result) = result.map { |r| r["slug"] }
  def weight_of(result, slug) = result.find { |r| r["slug"] == slug }&.fetch("weight")

  # --- domain fit ---

  test "a backend task puts the backend reviewer (carl) in the heavy seat" do
    result = ReviewerSelector.select(task_for(shape: "backend"))

    assert_equal 2, result.size
    assert_equal slugs(result).uniq, slugs(result), "two distinct reviewers"
    assert_includes slugs(result), "carl"
    assert_equal "heavy", weight_of(result, "carl"), "the domain owner takes the heavy (deep) seat"
    assert_equal %w[heavy light].sort, result.map { |r| r["weight"] }.sort, "exactly one heavy + one light"
  end

  test "an onchain task selects the Web3 reviewer (jasper) as heavy" do
    result = ReviewerSelector.select(task_for(shape: "onchain"))
    assert_includes slugs(result), "jasper"
    assert_equal "heavy", weight_of(result, "jasper")
  end

  test "a ui-only task selects the UI reviewer (shannon) as heavy" do
    result = ReviewerSelector.select(task_for(shape: "ui-only"))
    assert_includes slugs(result), "shannon"
    assert_equal "heavy", weight_of(result, "shannon")
  end

  test "a risk tag pulls its domain owner in even on a different shape" do
    # A backend shape carrying a `solana` risk tag should pull the Web3 reviewer in.
    result = ReviewerSelector.select(task_for(shape: "backend", risks: ["solana"]))
    assert_includes slugs(result), "carl", "the backend shape owner still fits"
    assert_includes slugs(result), "jasper", "the solana risk pulls the Web3 reviewer in"
  end

  test "an on-chain repo pulls the Web3 reviewer in even on a backend shape" do
    # A backend-shaped change living in turf-vault still wants Jasper's eyes —
    # the repo carries the Web3 signal the shape alone misses.
    result = ReviewerSelector.select(task_for(shape: "backend", repos: ["turf-vault"]))
    assert_includes slugs(result), "carl", "the backend shape owner still fits"
    assert_includes slugs(result), "jasper", "the turf-vault repo pulls the Web3 reviewer in"
  end

  # --- the documentation persona is the pool's docs seat (alex-docs, not alex) ---

  test "a docs change selects the documentation persona (alex-docs), not the orchestrator" do
    # `docs` is the only needed domain → only the docs persona fits → heavy seat.
    result = ReviewerSelector.select(task_for(shape: nil, risks: ["docs"]))
    assert_includes slugs(result), "alex-docs", "the docs persona is the pool's documentation seat"
    refute_includes slugs(result), "alex", "the orchestrator seat never reviews"
    assert_equal "heavy", weight_of(result, "alex-docs"), "the docs-domain owner takes the heavy seat"
  end

  # --- no self-gating: the QA owner (steffon) is never a reviewer ---

  test "steffon is never picked — he QAs the assembled RC, so reviewing too would self-gate" do
    Task::SHAPES.each do |shape|
      result = ReviewerSelector.select(task_for(shape: shape))
      refute_includes slugs(result), "steffon", "steffon must be excluded on a #{shape} task"
    end
  end

  test "a custom qa_owner is the one excluded (the rule is 'whoever QAs this task')" do
    result = ReviewerSelector.new(task_for(shape: "backend"), qa_owner: "carl").reviewers
    refute_includes slugs(result), "carl", "the named QA owner is excluded instead"
  end

  # --- logged random tiebreak ---

  test "the random tiebreak is logged (auditable review spread)" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), logger: logger).reviewers

    line = logger.lines.last
    assert_match(/\[reviewer-selector\]/, line)
    assert_match(/rolls=/, line, "the per-candidate random rolls are logged")
    assert_match(/chosen=/, line, "the chosen pair is logged")
  end

  test "a seeded random produces a deterministic, reproducible pair" do
    a = ReviewerSelector.new(task_for(shape: "backend"), random: Random.new(42)).reviewers
    b = ReviewerSelector.new(task_for(shape: "backend"), random: Random.new(42)).reviewers
    assert_equal a, b, "same seed → same selection (the tiebreak is the only nondeterminism)"
  end

  # --- graceful degradation: works without the reviewer Agent rows ---

  test "selection works with no reviewer Agent rows (built-in defaults)" do
    Agent.delete_all

    result = ReviewerSelector.select(task_for(shape: "backend"))
    assert_equal 2, result.size
    assert_equal slugs(result).uniq, slugs(result)
    assert_equal %w[heavy light].sort, result.map { |r| r["weight"] }.sort
    refute_includes slugs(result), "steffon"
  end

  test "an unknown / blank shape still returns a valid heavy+light pair" do
    result = ReviewerSelector.select(Task.create!(title: "no shape sample task", stage: "submitted"))
    assert_equal 2, result.size
    assert_equal %w[heavy light].sort, result.map { |r| r["weight"] }.sort
  end

  # --- reads Agent.metadata domains + review_weight ---

  test "reads Agent.metadata domains for fit and review_weight for the heavy seat" do
    # Both reviewers are made to fit backend via metadata; the heavier review_weight
    # takes the heavy seat — proving both metadata keys drive the decision.
    seed_agent("Carl", domains: ["backend"], review_weight: 9)
    seed_agent("Shannon", domains: ["backend"], review_weight: 1)

    result = ReviewerSelector.select(task_for(shape: "backend"))

    assert_equal %w[carl shannon], slugs(result).sort, "both metadata-fitted reviewers are picked"
    assert_equal "heavy", weight_of(result, "carl"), "higher review_weight → heavy seat"
    assert_equal "light", weight_of(result, "shannon")
  end

  # --- explain: the auditable decision the CLI (bin/reviewer-select) prints ---

  test "explain returns the chosen pair, their matched domains, and the excluded QA owner" do
    decision = ReviewerSelector.explain(task_for(shape: "backend"))

    assert_equal %w[heavy light], decision["reviewers"].map { |r| r["weight"] }, "one heavy + one light, heavy first"
    heavy = decision["reviewers"].first
    assert_equal "carl", heavy["slug"], "the backend owner takes the heavy seat"
    assert_includes heavy["matched"], "backend", "the seat shows which needed domains it covers"
    assert_equal "steffon", decision["excluded_qa_owner"]
    refute_includes decision["candidates"], "steffon", "the QA owner is not a candidate (no self-gating)"
  end

  test "explain's ranked list is the auditable tiebreak — every candidate with its roll" do
    decision = ReviewerSelector.explain(task_for(shape: "backend"))

    assert_equal decision["candidates"].sort, decision["ranked"].map { |c| c["slug"] }.sort,
      "every candidate appears in the ranking"
    assert(decision["ranked"].all? { |c| c["roll"].is_a?(Numeric) }, "each candidate carries a logged roll")
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "two distinct seniors"
  end

  test "explain is deterministic under a seeded random (the tiebreak is the only nondeterminism)" do
    task = task_for(shape: "backend")
    a = ReviewerSelector.new(task, random: Random.new(7)).decision
    b = ReviewerSelector.new(task, random: Random.new(7)).decision
    assert_equal a, b
  end
end
