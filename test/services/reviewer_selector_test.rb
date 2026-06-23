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

  # --- no self-reviewing: the builder is never a reviewer of their own work ---

  # A selector whose pool is shrunk to three souls — lets the too-few-candidates
  # fallback be exercised with the real logic, no frozen-constant mutation. With
  # the QA owner out, two remain (a formable pair); dropping the builder too would
  # leave one — so the fallback must KEEP the builder.
  class TinyPoolSelector < ReviewerSelector
    def pool = %w[carl shannon jasper]
  end

  test "an explicit builder is excluded from the candidate pool" do
    result = ReviewerSelector.new(task_for(shape: "backend"), builder: "carl").reviewers
    refute_includes slugs(result), "carl", "the builder never reviews their own work"
    assert_equal 2, result.size, "a heavy+light pair is still returned"
  end

  test "the builder recorded on devops.built_by is excluded" do
    task = task_for(shape: "backend")
    task.update!(metadata: task.metadata.deep_merge("devops" => { "built_by" => "carl" }))

    decision = ReviewerSelector.explain(task)
    refute_includes decision["candidates"], "carl", "devops.built_by is read as the builder"
    assert_equal "carl", decision["builder"]
    assert_equal "carl", decision["excluded_builder"]
  end

  test "the builder is derived from the latest building TaskEvent actor" do
    # A task with NO devops.built_by but a building event whose actor is carl —
    # the persisted-task fallback the model-path selection (stage_event_metadata)
    # relies on. Build the event with the actor, then strip the stamped scalar so
    # only the event-actor path can supply the builder.
    task = nil
    begin
      Current.task_event_actor = "carl"
      task = Task.create!(title: "builder via building event task", stage: "building",
                          metadata: { "devops" => { "shape" => "backend" } })
    ensure
      Current.reset
    end
    task.update_columns(metadata: { "devops" => { "shape" => "backend" } }) # drop the stamped built_by

    decision = ReviewerSelector.explain(task)
    assert_equal "carl", decision["builder"], "derived from the → building event actor"
    refute_includes decision["candidates"], "carl"
  end

  test "the QA owner and the builder are excluded together" do
    decision = ReviewerSelector.new(task_for(shape: "backend"), qa_owner: "steffon", builder: "carl").decision
    refute_includes decision["candidates"], "steffon", "the QA owner stays excluded"
    refute_includes decision["candidates"], "carl", "and the builder is excluded too"
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size
  end

  test "an unknown builder degrades to a domain-only pick (QA owner still excluded)" do
    decision = ReviewerSelector.explain(task_for(shape: "backend"))
    assert_nil decision["builder"], "no builder known"
    assert_nil decision["excluded_builder"]
    refute_includes decision["candidates"], "steffon", "the QA-owner exclusion still applies"
    assert_includes decision["candidates"], "carl", "the domain owner stays eligible when builder is unknown"
  end

  test "a known builder outside the pool excludes nobody and isn't reported excluded" do
    # `mack` is a real soul but NOT in the reviewer POOL — there's nothing to
    # remove, so the audit must not claim an exclusion (the old bug reported
    # excluded_builder for a non-candidate) and the candidate set is unchanged.
    baseline = ReviewerSelector.explain(task_for(shape: "backend"))["candidates"]
    decision = ReviewerSelector.new(task_for(shape: "backend"), builder: "mack").decision

    assert_equal "mack", decision["builder"], "the builder is still identified"
    assert_nil decision["excluded_builder"], "a non-pool builder excludes nobody — no false (excluded)"
    assert_equal baseline.sort, decision["candidates"].sort, "the candidate set is unchanged"
  end

  test "the builder is KEPT when excluding it would leave too few candidates" do
    # Pool {carl, shannon, jasper}; qa_owner=jasper leaves {carl, shannon} (a
    # formable pair); excluding builder carl too would leave only {shannon} — so
    # the builder is kept and a heavy+light pair is still returned.
    selector = TinyPoolSelector.new(task_for(shape: "backend"), qa_owner: "jasper", builder: "carl")
    decision = selector.decision

    assert_includes decision["candidates"], "carl", "builder kept — excluding would leave too few"
    assert_equal "carl", decision["builder"], "the builder is still identified"
    assert_nil decision["excluded_builder"], "but it was NOT excluded (degraded to keep)"
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "a pair is still returned"
  end

  test "the audit log names the builder and its exclusion state" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), builder: "carl", logger: logger).reviewers

    line = logger.lines.last
    assert_match(/builder=carl\(excluded\)/, line, "the builder + its state is logged")
  end

  test "the audit log shows builder=- when the builder is unknown" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), logger: logger).reviewers

    assert_match(/builder=-/, logger.lines.last)
  end

  test "the audit log marks a known non-pool builder as not-a-candidate" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), builder: "mack", logger: logger).reviewers

    assert_match(/builder=mack\(not-a-candidate\)/, logger.lines.last,
      "a known builder outside the pool is flagged not-a-candidate, never kept:too-few")
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

  # --- weight + roll follow-ups (PR #123 review: reviewer-select-weight-followups) ---

  test "string review_weight labels drive the heavy seat regardless of the roll" do
    # Regression: prod seeds (db/seeds/02_agents.rb) store review_weight as the
    # STRING "heavy"/"light". A bare String#to_f silently zeroed every label
    # (-> 0.0), so the label never drove the deep seat — fit (then the roll)
    # broke the tie instead. Both reviewers fit backend equally here, so the
    # weight LABEL is the only thing that can decide who reviews deep — and it
    # must win under EVERY tiebreak roll, not just some.
    seed_agent("Carl", domains: ["backend"], review_weight: "light")
    seed_agent("Shannon", domains: ["backend"], review_weight: "heavy")
    task = task_for(shape: "backend")

    8.times do |seed|
      result = ReviewerSelector.new(task, random: Random.new(seed)).reviewers
      assert_equal %w[carl shannon], slugs(result).sort, "both backend-fitted reviewers are picked"
      assert_equal "heavy", weight_of(result, "shannon"), "the 'heavy' label must drive the deep seat (seed=#{seed})"
      assert_equal "light", weight_of(result, "carl")
    end
  end

  test "the CLI decision and the recorded pick never diverge on a genuine tie" do
    # Regression: bin/reviewer-select prints .decision while Task records .select —
    # two INDEPENDENT passes. On a genuine tie (no shape/risk/repo -> every
    # candidate fit 0 and equal weight) a fresh process RNG let them diverge: Avi
    # could spawn one pair while the timeline records another. The default
    # tiebreak RNG is now seeded from the task identity, so independent passes
    # roll identically and the CLI preview always matches the recorded pick.
    task = Task.create!(title: "genuine tie sample task", stage: "submitted")

    cli_pair = ReviewerSelector.explain(task)["reviewers"].map { |r| r["slug"] }
    recorded = Array.new(8) { ReviewerSelector.select(task).map { |r| r["slug"] } }

    assert_equal 1, recorded.uniq.size,
      "independent passes must pick one stable pair (no process-random divergence)"
    assert_equal cli_pair, recorded.first,
      "the CLI .decision preview must match the recorded .select pick (heavy/light order included)"
  end

  test "the CLI preview and recorded pick agree on a tie WITH a builder excluded" do
    # The seed folds in the EXCLUDED builder, so two passes that exclude the same
    # builder roll over the SAME post-exclusion pool — they must still agree. A
    # genuine tie (no shape/risk/repo) means the seeded tiebreak is the ONLY thing
    # deciding the pair, and the excluded builder (carl, via devops.built_by) is
    # really out of both passes.
    task = Task.create!(title: "tie with builder excluded task", stage: "submitted",
                        metadata: { "devops" => { "built_by" => "carl" } })

    decision = ReviewerSelector.explain(task)
    assert_equal "carl", decision["excluded_builder"], "the builder is excluded from both passes"
    refute_includes decision["candidates"], "carl", "carl is out of the candidate pool"

    cli_pair = decision["reviewers"].map { |r| r["slug"] }
    recorded = Array.new(8) { ReviewerSelector.select(task).map { |r| r["slug"] } }

    assert_equal 1, recorded.uniq.size, "the seeded tiebreak gives one stable pair over the carl-excluded pool"
    refute_includes recorded.first, "carl", "the excluded builder is never in the recorded pair"
    assert_equal cli_pair, recorded.first,
      "CLI preview == recorded pick even with a builder folded into the seed"
  end
end
