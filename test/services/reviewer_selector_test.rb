require "test_helper"

# ReviewerSelector picks the reviewer pair for a submitted PR under the
# Carl-owns-review model: **Carl is the STANDING PRIMARY** (Lead Architect, deep
# reviewer + owner) on every PR, and the selection only chooses the LIGHT (focused
# second read) — a domain-fit pick from the specialist pool {shannon, jasper,
# steffon, alex}, with a LOGGED random tiebreak, never the QA owner (no
# self-gating). Carl yields the primary seat only to the hard no-self-review rule
# (he built the task, or a caller names him the qa_owner). It degrades gracefully
# when the soul Agent rows aren't seeded.
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
  def primary_slug(result) = result.find { |r| r["weight"] == "primary" }&.fetch("slug")
  def light_slug(result) = result.find { |r| r["weight"] == "light" }&.fetch("slug")

  # --- Carl is the standing primary on every PR ---

  test "Carl takes the primary seat on every shape" do
    Task::SHAPES.each do |shape|
      result = ReviewerSelector.select(task_for(shape: shape))
      assert_equal 2, result.size
      assert_equal slugs(result).uniq, slugs(result), "two distinct reviewers on a #{shape} task"
      assert_equal "carl", primary_slug(result), "Carl is the standing primary on a #{shape} task"
      assert_equal %w[primary light].sort, result.map { |r| r["weight"] }.sort, "exactly one primary + one light"
    end
  end

  test "a backend task pairs primary Carl with a non-Carl light specialist" do
    result = ReviewerSelector.select(task_for(shape: "backend"))
    assert_equal "carl", primary_slug(result)
    refute_equal "carl", light_slug(result), "the light is a specialist, never Carl"
    refute_equal "avi", light_slug(result), "the QA owner (avi) is never the light"
    assert_includes %w[shannon jasper steffon alex], light_slug(result), "the light is drawn from the specialist pool"
  end

  # --- the LIGHT is a domain-fit pick from the specialist pool ---

  test "an onchain task selects the Web3 specialist (jasper) as the light" do
    result = ReviewerSelector.select(task_for(shape: "onchain"))
    assert_equal "carl", primary_slug(result)
    assert_equal "jasper", light_slug(result), "the Web3 specialist is the domain light"
  end

  test "a ui-only task selects the UI specialist (shannon) as the light" do
    result = ReviewerSelector.select(task_for(shape: "ui-only"))
    assert_equal "carl", primary_slug(result)
    assert_equal "shannon", light_slug(result)
  end

  test "a docs-shaped task selects Alex (the documentation seat) as the light" do
    result = ReviewerSelector.select(task_for(shape: "docs"))
    assert_equal "carl", primary_slug(result)
    assert_equal "alex", light_slug(result), "the docs shape routes the light to Alex"
  end

  test "a risk tag pulls its domain specialist into the light seat even on a backend shape" do
    # A backend shape carrying a `solana` risk tag: Carl still owns the deep read,
    # and the solana risk pulls the Web3 specialist into the light seat.
    result = ReviewerSelector.select(task_for(shape: "backend", risks: ["solana"]))
    assert_equal "carl", primary_slug(result)
    assert_equal "jasper", light_slug(result), "the solana risk pulls the Web3 specialist into the light"
  end

  test "an on-chain repo pulls the Web3 specialist into the light seat even on a backend shape" do
    result = ReviewerSelector.select(task_for(shape: "backend", repos: ["turf-vault"]))
    assert_equal "carl", primary_slug(result)
    assert_equal "jasper", light_slug(result), "the turf-vault repo pulls the Web3 specialist into the light"
  end

  # --- no self-gating: the QA owner (avi) is never a reviewer; steffon rejoined ---

  test "avi (the default QA owner) is never a light reviewer — he runs qa-release, so reviewing too would self-gate" do
    Task::SHAPES.each do |shape|
      result = ReviewerSelector.select(task_for(shape: shape))
      refute_includes slugs(result), "avi", "avi must be excluded on a #{shape} task (he QAs the assembled RC)"
    end
  end

  test "steffon rejoins the light pool after the reslot — avi is the QA owner now" do
    decision = ReviewerSelector.explain(task_for(shape: "backend"))
    assert_equal "avi", decision["excluded_qa_owner"], "the default QA-owner exclusion targets avi"
    assert_includes decision["candidates"], "steffon",
      "steffon is a light candidate again (he moved to production-deploy, no longer the QA owner)"
  end

  test "a custom qa_owner is excluded from the light seat" do
    result = ReviewerSelector.new(task_for(shape: "onchain"), qa_owner: "jasper").reviewers
    assert_equal "carl", primary_slug(result), "Carl still owns the primary seat"
    refute_includes slugs(result), "jasper", "the named QA owner is excluded from the light"
  end

  # --- no self-review: Carl yields the primary seat when HE built the task ---

  test "when Carl built the task he reviews nothing and both seats are domain picks" do
    result = ReviewerSelector.new(task_for(shape: "onchain"), builder: "carl").reviewers
    refute_includes slugs(result), "carl", "the builder never reviews their own work — not even Carl"
    assert_equal 2, result.size, "a primary+light pair still forms from the specialist pool"
    assert_equal slugs(result).uniq, slugs(result), "two distinct specialists"
    refute_includes slugs(result), "avi", "the QA owner (avi) stays excluded"
    # onchain needs web3 → jasper is the best fit and takes the (yielded) deep seat.
    assert_equal "jasper", primary_slug(result), "the best-fit specialist takes the yielded deep seat"
  end

  test "when Carl is named qa_owner he yields the primary seat too" do
    result = ReviewerSelector.new(task_for(shape: "backend"), qa_owner: "carl").reviewers
    refute_includes slugs(result), "carl", "the QA owner never reviews — not even Carl"
    assert_equal 2, result.size
  end

  # --- specialist builder is excluded from the light seat ---

  test "an explicit specialist builder is excluded from the light seat" do
    result = ReviewerSelector.new(task_for(shape: "ui-only"), builder: "shannon").reviewers
    assert_equal "carl", primary_slug(result), "Carl is unaffected — he is the standing primary"
    refute_includes slugs(result), "shannon", "the specialist builder never reviews their own work"
    assert_equal 2, result.size
  end

  test "the specialist builder recorded on devops.built_by is excluded from the light pool" do
    task = task_for(shape: "ui-only")
    task.update!(metadata: task.metadata.deep_merge("devops" => { "built_by" => "shannon" }))

    decision = ReviewerSelector.explain(task)
    refute_includes decision["candidates"], "shannon", "devops.built_by is read as the builder"
    assert_equal "shannon", decision["builder"]
    assert_equal "shannon", decision["excluded_builder"]
    assert_equal "carl", decision["standing_primary"], "Carl remains the standing primary"
  end

  test "the builder is derived from the latest building TaskEvent actor" do
    # A task with NO devops.built_by but a building event whose actor is shannon —
    # the persisted-task fallback the model-path selection relies on.
    task = nil
    begin
      Current.task_event_actor = "shannon"
      task = Task.create!(title: "builder via building event task", stage: "building",
                          metadata: { "devops" => { "shape" => "ui-only" } })
    ensure
      Current.reset
    end
    task.update_columns(metadata: { "devops" => { "shape" => "ui-only" } }) # drop the stamped built_by

    decision = ReviewerSelector.explain(task)
    assert_equal "shannon", decision["builder"], "derived from the → building event actor"
    refute_includes decision["candidates"], "shannon"
  end

  test "Carl-the-builder is excluded from the primary seat but reported as not-a-light-candidate" do
    decision = ReviewerSelector.new(task_for(shape: "backend"), builder: "carl").decision
    assert_equal "carl", decision["builder"], "Carl is identified as the builder"
    assert_nil decision["excluded_builder"], "Carl isn't a light candidate, so nothing is excluded from the light pool"
    assert_nil decision["standing_primary"], "Carl has yielded the standing primary seat"
    refute_includes decision["candidates"], "carl", "Carl is never in the light pool"
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "carl"
  end

  test "an unknown builder degrades to a domain-only light (QA owner still excluded)" do
    decision = ReviewerSelector.explain(task_for(shape: "backend"))
    assert_nil decision["builder"], "no builder known"
    assert_nil decision["excluded_builder"]
    assert_equal "carl", decision["standing_primary"]
    assert_equal "avi", decision["excluded_qa_owner"], "the QA-owner exclusion targets avi"
    assert_includes decision["candidates"], "steffon", "steffon is a light candidate again"
  end

  # --- the builder fact is REPORTED, so a caller can fail closed on it ---
  # (builder-stamp-misses-reviewer-guard). The list of excluded souls was always
  # computed correctly; the defect was that it was EMPTY and nothing said so.

  test "an unknown builder is REPORTED as unknown, not silently treated as none" do
    decision = ReviewerSelector.explain(task_for(shape: "backend"))
    assert_equal false, decision["builder_known"],
      "an absent builder is an UNKNOWN fact — the caller must be able to refuse on it"
  end

  test "a stamped soul builder is reported as known" do
    task = task_for(shape: "ui-only")
    task.update!(metadata: task.metadata.deep_merge("devops" => { "built_by" => "shannon" }))

    decision = ReviewerSelector.explain(task)
    assert_equal true, decision["builder_known"]
    assert_equal "shannon", decision["excluded_builder"], "and the exclusion actually fires"
  end

  test "a session-id building actor is NOT a known builder" do
    # The fail-open one layer down: the TaskEvent fallback returned the raw actor,
    # and a bare `bin/task move … building` writes the session UUID there. A
    # presence check would have called that "builder known" while excluding nobody.
    task = nil
    begin
      Current.task_event_actor = "942a9824-375f-4d13-b60e-85be79ee9880"
      task = Task.create!(title: "uuid actor builder task", stage: "building",
                          metadata: { "devops" => { "shape" => "backend" } })
    ensure
      Current.reset
    end

    decision = ReviewerSelector.explain(task)
    assert_nil decision["builder"], "a session id is not a soul"
    assert_equal false, decision["builder_known"], "an unresolvable actor leaves the builder UNKNOWN"
  end

  test "an explicit no-builder assertion makes the builder known with nobody excluded" do
    # The escape hatch that keeps the guard usable: a caller who KNOWS no soul
    # built the task states it, and the fact stops being absent.
    decision = ReviewerSelector.new(task_for(shape: "backend"), builder: ReviewerSelector::NO_BUILDER).decision
    assert_equal true, decision["builder_known"], "an asserted absence is a known fact"
    assert_nil decision["builder"], "nobody is named as the builder"
    assert_nil decision["excluded_builder"], "and nobody is excluded"
    assert_equal "carl", decision["standing_primary"], "Carl keeps the primary seat"
  end

  test "NO soul in the pool is ever seated on a task it is recorded as building" do
    # The PROPERTY, asserted over the whole pool and every shape rather than the
    # one spelling that failed. The seats are what matter: a builder that survives
    # into `reviewers` is a self-review no matter how the exclusion list reads.
    ReviewerSelector::POOL.each do |soul|
      Task::SHAPES.each do |shape|
        task = task_for(shape: shape)
        task.update!(metadata: task.metadata.deep_merge("devops" => { "built_by" => soul }))

        seated = slugs(ReviewerSelector.select(task))
        refute_includes seated, soul, "#{soul} was seated on a #{shape} task #{soul} built"
        assert_equal 2, seated.uniq.size, "a full pair still forms on a #{shape} task"
      end
    end
  end

  test "a non-soul builder override leaves the builder unknown" do
    decision = ReviewerSelector.new(task_for(shape: "backend"), builder: "session-42a9").decision
    assert_equal false, decision["builder_known"], "a non-soul override names nobody"
  end

  test "a known non-specialist builder excludes nobody from the light pool" do
    # `mack` is a real soul but NOT a specialist — there's nothing to remove from
    # the light pool, so the audit must not claim an exclusion.
    baseline = ReviewerSelector.explain(task_for(shape: "backend"))["candidates"]
    decision = ReviewerSelector.new(task_for(shape: "backend"), builder: "mack").decision

    assert_equal "mack", decision["builder"], "the builder is still identified"
    assert_nil decision["excluded_builder"], "a non-specialist builder excludes nobody"
    assert_equal baseline.sort, decision["candidates"].sort, "the light candidate set is unchanged"
  end

  # A selector whose pool is shrunk so the too-few-candidates fallback is exercised
  # with real logic (no frozen-constant mutation). Light pool = {shannon, jasper}.
  class TinyPoolSelector < ReviewerSelector
    def pool = %w[carl shannon jasper]
  end

  test "a specialist builder is KEPT when excluding it would leave too few lights" do
    # Carl is named qa_owner, so he yields the primary seat and BOTH seats are drawn
    # from the light pool {shannon, jasper} — a floor of 2. Excluding builder shannon
    # would leave only {jasper}, so the builder is KEPT and a pair still forms.
    decision = TinyPoolSelector.new(task_for(shape: "backend"), qa_owner: "carl", builder: "shannon").decision

    assert_includes decision["candidates"], "shannon", "builder kept — excluding would leave too few lights"
    assert_equal "shannon", decision["builder"], "the builder is still identified"
    assert_nil decision["excluded_builder"], "but it was NOT excluded (degraded to keep)"
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "a pair is still returned"
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "carl", "carl (qa owner) reviews nothing"
  end

  test "the audit log names a specialist builder and its exclusion state" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "ui-only"), builder: "shannon", logger: logger).reviewers

    assert_match(/builder=shannon\(excluded\)/, logger.lines.last, "the builder + its state is logged")
  end

  test "the audit log shouts UNKNOWN when the builder is unknown" do
    # It logged a bare `builder=-` until 2026-08-13, which is exactly why two
    # blind picks went unnoticed in one day: a disabled safety check must not read
    # like a tidy empty field.
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), logger: logger).reviewers

    assert_match(/builder=UNKNOWN\(no-exclusion\)/, logger.lines.last)
  end

  test "the audit log distinguishes an ASSERTED absence from an unknown builder" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), builder: ReviewerSelector::NO_BUILDER,
                                                     logger: logger).reviewers

    assert_match(/builder=none\(asserted\)/, logger.lines.last,
      "a stated fact is auditable as a stated fact, not as a missing one")
  end

  test "the audit log marks a known non-specialist builder as not-a-candidate" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), builder: "mack", logger: logger).reviewers

    assert_match(/builder=mack\(not-a-candidate\)/, logger.lines.last,
      "a known builder outside the specialist pool is flagged not-a-candidate")
  end

  test "the audit log flags Carl-the-builder as not-a-candidate for the light pool" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), builder: "carl", logger: logger).reviewers

    assert_match(/builder=carl\(not-a-candidate\)/, logger.lines.last,
      "Carl the builder is out of the primary seat, but he was never a light candidate")
  end

  # --- busy exclusion: specialists mid-build / mid-review on OTHER tasks ---

  test "a busy specialist passed to the selector is excluded from the light candidates" do
    decision = ReviewerSelector.new(task_for(shape: "backend"), busy: ["jasper"]).decision
    refute_includes decision["candidates"], "jasper", "a busy soul is not a light candidate"
    assert_equal ["jasper"], decision["excluded_busy"]
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "jasper"
    assert_equal "carl", decision["reviewers"].first["slug"], "Carl is unaffected by busy specialists"
  end

  test "the busy set is auto-excluded with no manual flag and reported in the audit" do
    decision = ReviewerSelector.new(task_for(shape: "backend"), busy: %w[jasper alex]).decision
    %w[jasper alex].each { |slug| refute_includes decision["candidates"], slug }
    assert_equal %w[alex jasper], decision["excluded_busy"].sort
    assert_equal [], decision["kept_busy"]
    assert_equal "carl", decision["reviewers"].first["slug"]
    assert_equal "shannon", light_slug(decision["reviewers"]), "the one remaining specialist is the light"
  end

  test "the busy filter keeps the least-bad busy back rather than starve the light pool" do
    # TinyPool lights {shannon, jasper}; Carl is the standing primary (min light = 1).
    # Marking BOTH busy can't drop below one light — the filter keeps the least-bad
    # one eligible so a carl + light pair still forms.
    decision = TinyPoolSelector.new(task_for(shape: "backend"), busy: %w[shannon jasper]).decision

    assert_equal 1, decision["candidates"].size, "one light is always kept back"
    assert_equal 1, decision["excluded_busy"].size, "only the surplus busy soul is removed"
    assert_equal 1, decision["kept_busy"].size, "the least-bad busy soul is kept eligible"
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "carl + the kept light"
    assert_equal "carl", decision["reviewers"].first["slug"]
  end

  test "a busy soul that isn't a light candidate excludes nobody" do
    # `mack` isn't a specialist and `avi` is the QA owner (never in the light pool) —
    # neither is a removable candidate, so the busy filter is a no-op for them.
    baseline = ReviewerSelector.explain(task_for(shape: "backend"))["candidates"]
    decision = ReviewerSelector.new(task_for(shape: "backend"), busy: %w[mack avi]).decision

    assert_equal [], decision["excluded_busy"], "a non-candidate busy soul removes nobody"
    assert_equal baseline.sort, decision["candidates"].sort, "the light candidate set is unchanged"
  end

  test "the builder, the QA owner, and a busy soul are all excluded from the light pool together" do
    decision = ReviewerSelector.new(task_for(shape: "ui-only"),
                                    qa_owner: "steffon", builder: "shannon", busy: ["jasper"]).decision

    %w[steffon shannon jasper].each do |slug|
      refute_includes decision["candidates"], slug, "#{slug} is excluded from the light pool"
    end
    assert_equal "shannon", decision["excluded_builder"]
    assert_equal ["jasper"], decision["excluded_busy"]
    assert_equal "carl", decision["reviewers"].first["slug"], "Carl is the standing primary"
    assert_equal "alex", light_slug(decision["reviewers"]), "the last remaining specialist is the light"
  end

  test "the busy set folds into the seed so a busy-aware light pick is reproducible" do
    task = task_for(shape: "backend")
    a = ReviewerSelector.new(task, busy: ["jasper"]).reviewers
    b = ReviewerSelector.new(task, busy: ["jasper"]).reviewers
    assert_equal a, b, "two passes with the same busy set roll identically"
  end

  test "an empty busy set leaves selection unchanged (default behavior)" do
    task = task_for(shape: "backend")
    with_busy = ReviewerSelector.new(task, busy: []).decision
    without = ReviewerSelector.explain(task)
    assert_equal [], with_busy["busy"]
    assert_equal [], with_busy["excluded_busy"]
    assert_equal without["reviewers"], with_busy["reviewers"],
      "an empty busy set must not perturb the seeded pick"
  end

  test "the audit log names the busy exclusions" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), busy: ["jasper"], logger: logger).reviewers
    assert_match(/busy=jasper/, logger.lines.last, "the excluded busy souls are logged")
  end

  # Integration: the real build flow (move-to-building auto-stamps built_by) feeding
  # the selector with a busy set — end-to-end the light omits BOTH the builder and
  # the busy soul, Carl owns the primary seat, and a pair still forms.
  test "the move-to-building builder and a busy soul are both omitted from the light end-to-end" do
    task = Task.create!(title: "build flow exclude integration", agent_slug: "shannon",
                        metadata: { "devops" => { "shape" => "ui-only" } })
    task.build! # the real move-to-building path stamps devops.built_by = shannon

    assert_equal "shannon", task.reload.devops_built_by, "built_by stamped through the build move"

    decision = ReviewerSelector.explain(task, busy: ["jasper"])
    assert_equal "shannon", decision["excluded_builder"], "the assigned builder is excluded from the light"
    assert_equal ["jasper"], decision["excluded_busy"], "the busy soul is excluded"
    %w[shannon jasper].each { |slug| refute_includes decision["candidates"], slug }
    assert_includes decision["candidates"], "steffon", "steffon stays eligible (avi is the QA owner now)"
    assert_equal "carl", decision["reviewers"].first["slug"], "Carl is the standing primary"
    assert_includes %w[steffon alex], light_slug(decision["reviewers"]), "the light is one of the remaining specialists"
  end

  # --- logged random tiebreak ---

  test "the random tiebreak is logged (auditable light spread)" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "backend"), logger: logger).reviewers

    line = logger.lines.last
    assert_match(/\[reviewer-selector\]/, line)
    assert_match(/primary=carl/, line, "the standing primary is logged")
    assert_match(/rolls=/, line, "the per-candidate random rolls are logged")
    assert_match(/chosen=carl\+/, line, "the chosen pair leads with Carl")
  end

  test "the yield case logs the primary as a yielded specialist" do
    logger = CapturingLogger.new
    ReviewerSelector.new(task_for(shape: "onchain"), builder: "carl", logger: logger).reviewers

    assert_match(/primary=jasper\(yield\)/, logger.lines.last,
      "when Carl builds it, the best-fit specialist takes the yielded deep seat")
  end

  test "a seeded random produces a deterministic, reproducible light pick" do
    a = ReviewerSelector.new(task_for(shape: "backend"), random: Random.new(42)).reviewers
    b = ReviewerSelector.new(task_for(shape: "backend"), random: Random.new(42)).reviewers
    assert_equal a, b, "same seed → same selection (the light tiebreak is the only nondeterminism)"
  end

  # --- graceful degradation: works without the reviewer Agent rows ---

  test "selection works with no reviewer Agent rows (built-in defaults)" do
    Agent.delete_all

    result = ReviewerSelector.select(task_for(shape: "backend"))
    assert_equal 2, result.size
    assert_equal slugs(result).uniq, slugs(result)
    assert_equal "carl", primary_slug(result), "Carl is the standing primary even with no Agent rows"
    assert_equal %w[primary light].sort, result.map { |r| r["weight"] }.sort
    refute_includes slugs(result), "avi", "the QA owner (avi) is never a reviewer"
  end

  test "an unknown / blank shape still returns a valid Carl+light pair" do
    result = ReviewerSelector.select(Task.create!(title: "no shape sample task", stage: "submitted"))
    assert_equal 2, result.size
    assert_equal "carl", primary_slug(result)
    assert_equal %w[primary light].sort, result.map { |r| r["weight"] }.sort
  end

  # --- reads Agent.metadata domains + review_weight for the LIGHT seat ---

  test "reads Agent.metadata domains for fit and review_weight to break a light tie" do
    # Two specialists made to fit backend equally via metadata; the heavier
    # review_weight takes the single LIGHT seat — proving both metadata keys drive
    # the light decision. Carl stays the standing primary. (Shannon + Jasper are
    # used because neither is a test fixture, so seed_agent can create them fresh.)
    seed_agent("Shannon", domains: ["backend"], review_weight: 9)
    seed_agent("Jasper", domains: ["backend"], review_weight: 1)

    result = ReviewerSelector.select(task_for(shape: "backend"))

    assert_equal "carl", primary_slug(result)
    assert_equal "shannon", light_slug(result), "higher review_weight → the light seat on a fit tie"
  end

  test "string review_weight labels break a light tie regardless of the roll" do
    # Regression: prod seeds store review_weight as the STRING "heavy"/"light". A
    # bare String#to_f silently zeroed every label, so the label never broke a tie.
    # Both specialists fit backend equally here, so the weight LABEL is the only
    # thing that can decide the single light seat — under EVERY tiebreak roll.
    seed_agent("Jasper", domains: ["backend"], review_weight: "light")
    seed_agent("Shannon", domains: ["backend"], review_weight: "heavy")
    task = task_for(shape: "backend")

    8.times do |seed|
      result = ReviewerSelector.new(task, random: Random.new(seed)).reviewers
      assert_equal "carl", primary_slug(result), "Carl is the standing primary (seed=#{seed})"
      assert_equal "shannon", light_slug(result), "the 'heavy' review_weight label wins the light seat (seed=#{seed})"
    end
  end

  # --- explain: the auditable decision the CLI (bin/reviewer-select) prints ---

  test "explain returns the chosen pair, their matched domains, and the excluded QA owner" do
    decision = ReviewerSelector.explain(task_for(shape: "onchain"))

    assert_equal %w[primary light], decision["reviewers"].map { |r| r["weight"] }, "one primary + one light, primary first"
    primary = decision["reviewers"].first
    assert_equal "carl", primary["slug"], "Carl takes the primary seat"
    light = decision["reviewers"].last
    assert_equal "jasper", light["slug"], "the Web3 specialist is the light"
    assert_includes light["matched"], "web3", "the light seat shows which needed domains it covers"
    assert_equal "avi", decision["excluded_qa_owner"]
    refute_includes decision["candidates"], "avi", "the QA owner is not a light candidate (no self-gating)"
    assert_includes decision["candidates"], "steffon", "steffon rejoined the light pool (avi is the QA owner now)"
    refute_includes decision["candidates"], "carl", "Carl is the standing primary, never a light candidate"
  end

  test "explain's ranked list is the auditable light tiebreak — every candidate with its roll" do
    decision = ReviewerSelector.explain(task_for(shape: "backend"))

    assert_equal decision["candidates"].sort, decision["ranked"].map { |c| c["slug"] }.sort,
      "every light candidate appears in the ranking"
    assert(decision["ranked"].all? { |c| c["roll"].is_a?(Numeric) }, "each candidate carries a logged roll")
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "two distinct reviewers"
  end

  test "explain is deterministic under a seeded random (the light tiebreak is the only nondeterminism)" do
    task = task_for(shape: "backend")
    a = ReviewerSelector.new(task, random: Random.new(7)).decision
    b = ReviewerSelector.new(task, random: Random.new(7)).decision
    assert_equal a, b
  end

  # --- reproducibility across the two independent passes (CLI vs recorder) ---

  test "the CLI decision and the recorded pick never diverge on a genuine tie" do
    # A genuine tie (no shape/risk/repo → every light fit 0, equal weight) means the
    # seeded tiebreak is the ONLY thing deciding the light. bin/reviewer-select prints
    # .decision while Task records .select — two INDEPENDENT passes that must agree.
    task = Task.create!(title: "genuine tie sample task", stage: "submitted")

    cli_pair = ReviewerSelector.explain(task)["reviewers"].map { |r| r["slug"] }
    recorded = Array.new(8) { ReviewerSelector.select(task).map { |r| r["slug"] } }

    assert_equal 1, recorded.uniq.size,
      "independent passes must pick one stable pair (no process-random divergence)"
    assert_equal cli_pair, recorded.first,
      "the CLI .decision preview must match the recorded .select pick (primary/light order included)"
    assert_equal "carl", cli_pair.first, "Carl is the standing primary even on a genuine tie"
  end

  test "the CLI preview and recorded pick agree on a tie WITH a specialist builder excluded" do
    # The seed folds in the EXCLUDED builder, so two passes that exclude the same
    # builder roll over the SAME post-exclusion light pool — they must still agree.
    task = Task.create!(title: "tie with builder excluded task", stage: "submitted",
                        metadata: { "devops" => { "built_by" => "shannon" } })

    decision = ReviewerSelector.explain(task)
    assert_equal "shannon", decision["excluded_builder"], "the builder is excluded from both passes"
    refute_includes decision["candidates"], "shannon", "shannon is out of the light pool"

    cli_pair = decision["reviewers"].map { |r| r["slug"] }
    recorded = Array.new(8) { ReviewerSelector.select(task).map { |r| r["slug"] } }

    assert_equal 1, recorded.uniq.size, "the seeded tiebreak gives one stable pair over the shannon-excluded pool"
    refute_includes recorded.first, "shannon", "the excluded builder is never in the recorded pair"
    assert_equal cli_pair, recorded.first,
      "CLI preview == recorded pick even with a builder folded into the seed"
  end
  # --- THE AUTHOR SET (reviewer-select-seats-authors) --------------------------
  # devops.built_by holds ONE soul, but a task can have SEVERAL: a session limit
  # kills a builder mid-work and another soul finishes it. built_by then names the
  # LAST claimant, and the pool excluded one author of two — which seated Alex on a
  # diff Alex had written every test on (PR #1081, 2026-08-30).

  def multi_author_task(shape: "backend", built_by: "steffon", builders: %w[steffon alex], unattributed: nil)
    devops = { "shape" => shape, "built_by" => built_by, "builders" => builders }
    devops["builders_unattributed"] = unattributed if unattributed
    task = task_for(shape: shape)
    task.update_columns(metadata: { "devops" => devops })
    task.reload
  end

  test "EVERY author on devops.builders is excluded from the light pool, not just built_by" do
    decision = ReviewerSelector.explain(multi_author_task)

    assert_equal %w[steffon alex], decision["builders"], "both authors are on record"
    refute_includes decision["candidates"], "alex", "the co-author is out of the light pool"
    refute_includes decision["candidates"], "steffon", "the recorded builder is out of the light pool"
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "alex",
      "the co-author must never take the light seat on their own diff"
  end

  test "NO author is ever seated, over every author PAIR and every shape" do
    # The PROPERTY, asserted over the whole pool rather than the one pairing that
    # failed live. Two authors is the shape a mid-build handoff produces.
    ReviewerSelector::POOL.combination(2).each do |first, second|
      Task::SHAPES.each do |shape|
        task = multi_author_task(shape: shape, built_by: second, builders: [first, second])

        seated = slugs(ReviewerSelector.select(task))
        refute_includes seated, first, "#{first} was seated on a #{shape} task #{first} co-authored"
        refute_includes seated, second, "#{second} was seated on a #{shape} task #{second} built"
        assert_equal 2, seated.uniq.size, "a full pair still forms on a #{shape} task"
      end
    end
  end

  test "Carl yields the primary seat when he is a CO-author, not merely the last claimant" do
    # `STANDING_PRIMARY != builder` could not see this: built_by names shannon, so
    # the old check left Carl on the deep seat for a diff Carl had worked on.
    decision = ReviewerSelector.explain(multi_author_task(built_by: "shannon", builders: %w[carl shannon]))

    assert_nil decision["standing_primary"], "Carl has yielded — he is one of the authors"
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "carl"
  end

  test "an author list known to be INCOMPLETE is not a known builder" do
    # The accumulator only helps while each claim names a soul. A handoff that named
    # NOBODY leaves a set of one that READS complete — the original bug, one layer
    # along — so the unattributed claim has to be able to say so.
    decision = ReviewerSelector.explain(
      multi_author_task(builders: %w[steffon], unattributed: "0198c0de-face-7000-b0b0-5eaced0ff1ce")
    )

    assert_equal %w[steffon], decision["builders"], "steffon is still on record"
    assert_equal false, decision["builder_known"],
      "a set missing a soul we cannot name is not a settled answer"
    assert_equal "0198c0de-face-7000-b0b0-5eaced0ff1ce", decision["builders_unattributed"],
      "and the decision names the session it could not attribute"
  end

  test "a complete two-author set IS known — incompleteness is the only new refusal" do
    # The guard must not refuse every multi-author task, or it gets routed around.
    assert_equal true, ReviewerSelector.explain(multi_author_task)["builder_known"]
  end

  test "an explicit override names SEVERAL authors and excludes them all" do
    # The hand-pass that saved the live review was `--busy alex`, which says the
    # wrong thing. Naming co-authors is now a first-class statement of the fact.
    decision = ReviewerSelector.new(task_for(shape: "backend"), builder: "steffon,alex").decision

    assert_equal %w[steffon alex], decision["builders"]
    assert_equal true, decision["builder_known"], "the caller has spoken for the task"
    refute_includes decision["candidates"], "alex"
    refute_includes decision["candidates"], "steffon"
  end

  test "an override CLEARS an unattributed gap — the caller stated the fact" do
    task = multi_author_task(builders: %w[steffon], unattributed: "sess-gone")
    decision = ReviewerSelector.new(task, builder: "steffon,alex").decision

    assert_equal true, decision["builder_known"], "an explicit override is authoritative"
    assert_nil decision["builders_unattributed"]
  end

  test "authors kept back for want of candidates are REPORTED, not silently seated" do
    # The pool yields rather than starve so the recorder never breaks; the residue is
    # a soul who MAY review their own diff, which bin/reviewer-select refuses on.
    task = multi_author_task(shape: "backend", built_by: "shannon", builders: %w[shannon jasper])
    decision = TinyPoolSelector.new(task, qa_owner: "carl").decision

    assert_equal %w[shannon jasper], decision["builders"]
    assert decision["kept_builders"].any?, "the two-soul light pool cannot drop both authors"
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "a pair still forms"
  end

  test "the audit log names EVERY author and its exclusion state" do
    logger = CapturingLogger.new
    ReviewerSelector.new(multi_author_task, logger: logger).reviewers

    assert_match(/builder=steffon\(excluded\),alex\(excluded\)/, logger.lines.last,
      "both authors and their exclusion state are on the audit line")
  end

  test "the audit log shouts UNKNOWN with the session it could not attribute" do
    logger = CapturingLogger.new
    ReviewerSelector.new(multi_author_task(builders: %w[steffon], unattributed: "sess-42"), logger: logger).reviewers

    assert_match(/builder=UNKNOWN\(unattributed:sess-42\)/, logger.lines.last)
  end

  test "a single-author task rolls the SAME light as before the author set existed" do
    # seed_for now folds the joined excluded SET. For zero and one author that string
    # is byte-for-byte the single slug it replaced, so no live task's default pick
    # shifted underneath this change.
    task = task_for(shape: "backend")
    task.update!(metadata: task.metadata.deep_merge("devops" => { "built_by" => "shannon" }))

    # The key the pre-change code built: "<slug>:<qa_owner>:<the one excluded slug>".
    pinned = ReviewerSelector.new(task, random: Random.new(Zlib.crc32("#{task.slug}:avi:shannon"))).decision
    assert_equal pinned["ranked"], ReviewerSelector.explain(task)["ranked"],
      "the default seed must still be byte-for-byte the single-slug key"
    assert_equal pinned["reviewers"], ReviewerSelector.explain(task)["reviewers"]
  end

  # --- THE ROSTER: an unrecognised soul cannot lift the refusal ----------------
  # #soul? was a SHAPE check (Task::SOUL_SLUG), satisfied by any lowercase word. So
  # a typo'd builder was a KNOWN builder that excluded NOBODY — the fail-closed
  # refusal lifted by a value identifying no one.

  test "a typo'd builder override names nobody and leaves the authors UNKNOWN" do
    decision = ReviewerSelector.new(task_for(shape: "backend"), builder: "stefon").decision

    assert_empty decision["builders"], "`stefon` is not a soul on the roster"
    assert_equal false, decision["builder_known"], "a typo must not do better than silence"
    assert_nil decision["excluded_builder"]
  end

  test "a typo'd built_by ON THE RECORD leaves the authors UNKNOWN" do
    task = task_for(shape: "backend")
    task.update_columns(metadata: { "devops" => { "shape" => "backend", "built_by" => "shanon" } })

    decision = ReviewerSelector.explain(task.reload)
    assert_equal false, decision["builder_known"], "a phantom on the record still refuses"
  end

  test "every seeded soul is still recognised — the roster narrows nothing real" do
    Task::SOUL_ROSTER.each do |soul|
      decision = ReviewerSelector.new(task_for(shape: "backend"), builder: soul).decision
      assert_equal true, decision["builder_known"], "#{soul} is a real soul and must be accepted"
      assert_equal soul, decision["builder"]
    end
  end

  test "the roster keeps its static floor with NO Agent rows at all" do
    # ReviewerSelector degrades to domain defaults with no DB (see its header). A
    # roster that emptied with the Agent table would turn every soul into an unknown
    # and refuse the whole fleet — fail-closed, but useless.
    Agent.delete_all
    Current.soul_roster = nil # the roster is memoized per request; this test IS a new one

    decision = ReviewerSelector.new(task_for(shape: "backend"), builder: "shannon").decision
    assert_equal true, decision["builder_known"], "the static floor still names the real souls"
    refute_includes decision["candidates"], "shannon"
    assert_equal false, ReviewerSelector.new(task_for(shape: "backend"), builder: "stefon").decision["builder_known"],
      "and a typo is still not a soul when the DB is empty"
  end

  test "a soul seeded ONLY in the database is recognised too" do
    Agent.create!(name: "Nova", slug: "nova")
    Current.soul_roster = nil # a soul seeded mid-request is seen on the NEXT one

    decision = ReviewerSelector.new(task_for(shape: "backend"), builder: "nova").decision
    assert_equal true, decision["builder_known"], "the roster unions the seeded slugs over the floor"
    assert_equal "nova", decision["builder"]
  end
end
