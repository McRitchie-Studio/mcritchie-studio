# Picks the TWO senior reviewers for a submitted task's PR — Avi's "delegate
# review to two seniors" step in the redesigned Deploy workflow
# (docs/agents/system/devops-cycle-design.md §1.2). Selection is by DOMAIN FIT
# (the task's shape + repositories + risk tags → the reviewer whose domains cover
# the change) with a LOGGED tiebreak, so reviews spread across the pool instead
# of always landing on the obvious domain owner. The pair is split 1 HEAVY (the
# deep review) / 1 LIGHT, driven by each reviewer's review_weight.
#
# The tiebreak RNG is seeded per-task by default (see #seed_for), so the
# selection is REPRODUCIBLE across processes: `bin/reviewer-select` (.decision)
# and the avatars recorder in Task (.select) compute the pair independently, and
# the seed makes both roll identically — the CLI preview always matches the
# recorded pick, even on a genuine tie. Different tasks still spread the picks.
#
# The pool is {shannon=UI · carl=backend · jasper=Web3 · steffon=DevOps/Platform ·
# alex-docs=Documentation} (alex-docs is Alex's launchable reviewer persona, the
# Documentation seat — distinct from the `alex` orchestrator seat, which does not
# review). The QA owner (Steffon, who QAs the assembled RC at the `assembled`
# step) is EXCLUDED so one soul never both reviews AND QAs the same change —
# "no self-gating" (§1.2). Steffon stays a valid reviewer for other PRs; pass a
# different `qa_owner:` when he isn't the one QAing this task.
#
# The BUILDER is excluded too — a soul shouldn't review their own work. Who built
# the task is read from devops.built_by (stamped from the build-claim actor when
# it resolves to a soul slug — see Task#stamp_builder) and, for a persisted task,
# falls back to the actor on the latest `→ building` TaskEvent; pass `builder:` to
# override. When the builder is unknown OR isn't in the selectable pool (a soul
# not in POOL, or the QA owner) the selection degrades to domain-only (QA-owner
# exclusion still applies) and the audit reports no excluded builder. If excluding
# a pool builder would leave fewer than two candidates the builder is KEPT (the
# decision/log flags it) so a pair is always returned.
#
# Reads each reviewer's Agent.metadata["domains"] + ["review_weight"]; DEGRADES
# GRACEFULLY to built-in defaults when the Agent row or those keys are absent, so
# selection works even before the reviewer souls are seeded.
#
# `bin/reviewer-select <task>` is the CLI wrapper Avi runs to choose; it prints
# the pair + the auditable tiebreak from `.explain`.
require "zlib"

class ReviewerSelector
  # The senior reviewer pool (slugs). `alex-docs` is the Documentation reviewer
  # persona (seeded in db/seeds/02_agents.rb), NOT the `alex` orchestrator seat.
  POOL = %w[shannon carl jasper steffon alex-docs].freeze

  # The soul who QAs the assembled RC at the `assembled` step — excluded from the
  # pool by default so a reviewer never gates their own QA (§1.2 "no self-gating").
  DEFAULT_QA_OWNER = "steffon"

  # A heavy + a light seat — the floor of candidates a selection needs. The
  # builder exclusion is skipped (builder kept) rather than drop below this.
  MIN_CANDIDATES = 2

  # Fallback domain tags per reviewer when an Agent row has no metadata["domains"].
  # Keep aligned with the seeded `domains` in db/seeds/02_agents.rb.
  DEFAULT_DOMAINS = {
    "shannon"   => %w[ui],
    "carl"      => %w[backend],
    "jasper"    => %w[web3 onchain],
    "steffon"   => %w[devops platform],
    "alex-docs" => %w[docs documentation]
  }.freeze

  # Neutral weight when an Agent row has no metadata["review_weight"].
  DEFAULT_REVIEW_WEIGHT = 1.0

  # The seeded review_weight LABELS → their numeric weight. The prod seeds
  # (db/seeds/02_agents.rb) store the human label, not a number; a bare
  # String#to_f would silently zero every label ("heavy".to_f == 0.0), so the
  # label never drove the heavy seat — fit broke the tie instead. Mapping the
  # labels here (heavy outranks light) makes the seeded weight actually
  # weight-driven, and keeps numeric weights (tests, future tuning) working too.
  WEIGHT_LABELS = { "heavy" => 2.0, "light" => 1.0 }.freeze

  # The task's shape → the review domains that change needs covered.
  SHAPE_DOMAINS = {
    "ui-only"          => %w[ui],
    "ui+db"            => %w[ui backend],
    "backend"          => %w[backend],
    "library"          => %w[backend],
    "onchain"          => %w[web3 onchain],
    "onchain-vertical" => %w[web3 onchain ui backend]
  }.freeze

  # A risk tag → the domain whose reviewer should weigh in (deepens the fit for
  # risk-bearing work — e.g. a `solana` tag pulls Web3 in even on a backend shape).
  RISK_DOMAINS = {
    "solana"    => "web3",
    "onchain"   => "web3",
    "payment"   => "backend",
    "migration" => "backend",
    "auth"      => "backend",
    "ui"        => "ui",
    "docs"      => "docs"
  }.freeze

  # A repo a task touches → the domain whose reviewer should weigh in. The
  # on-chain repos carry a strong Web3 signal the change's shape alone can miss
  # (e.g. a `backend` Ruby change inside solana-studio still wants Jasper's eyes).
  # ADDITIVE only — an unmapped repo contributes nothing, so shape + risk tags
  # stay authoritative and a task that names no repos is unaffected.
  REPO_DOMAINS = {
    "turf-vault"    => %w[web3 onchain],
    "solana-studio" => %w[web3 onchain]
  }.freeze

  # The TaskEvent.metadata["reviewers"] payload: [{ "slug" =>, "weight" => },…].
  def self.select(task, **opts)
    new(task, **opts).reviewers
  end

  # The full, auditable decision record for the CLI (bin/reviewer-select): the
  # chosen pair (heavy/light) PLUS the inputs, each reviewer's matched domains,
  # the excluded QA owner, and the per-candidate rolls + ranking — produced in
  # ONE ranked pass (one roll set) so what the CLI prints is exactly what was
  # picked. `.select` stays the slim canonical pick the model records.
  def self.explain(task, **opts)
    new(task, **opts).decision
  end

  # `builder:` overrides who built the task (else it's derived from the task —
  # see #builder). Pass it when the caller already knows the build agent.
  def initialize(task, qa_owner: DEFAULT_QA_OWNER, builder: nil, logger: nil, random: nil)
    @task = task
    @qa_owner = qa_owner.to_s
    @builder_override = builder.to_s.strip.presence
    @logger = logger || Rails.logger
    # Default the tiebreak RNG to a STABLE per-task seed. The default selection
    # must be reproducible across processes: bin/reviewer-select prints
    # `.decision` while the avatars recorder in Task computes `.select`
    # INDEPENDENTLY, so on a genuine fit+weight tie a fresh process RNG let them
    # diverge — Avi spawns one pair, the timeline records another. Seeding from
    # the task's own identity (+ the excluded QA owner AND excluded builder, which
    # set the candidate pool) makes both passes roll identically over the SAME
    # post-exclusion pool (the CLI preview always matches the recorded pick), while
    # different tasks still spread the picks. Tests pass an explicit `random:` to
    # pin a scenario.
    @random = random || Random.new(seed_for(@task, @qa_owner, builder_excluded? ? builder : nil))
  end

  # Exactly two entries — [{ "slug" =>, "weight" => "heavy" }, { … "light" }] —
  # string-keyed so it serializes straight into the jsonb event metadata.
  def reviewers
    heavy, light = split_heavy_light(pick_two)
    [
      { "slug" => heavy[:slug], "weight" => "heavy" },
      { "slug" => light[:slug], "weight" => "light" }
    ]
  end

  # The auditable selection detail behind #reviewers (see .explain) — string-keyed
  # so it serializes straight to JSON. One ranked pass, so the rolls reported here
  # are the rolls the pick was made on.
  def decision
    needs = needed_domains
    ordered = ranked
    heavy, light = split_heavy_light(ordered.first(2))
    {
      "task" => task.try(:slug),
      "shape" => task_shape,
      "repositories" => task_repositories,
      "risk_tags" => task_risk_tags,
      "needed_domains" => needs,
      "excluded_qa_owner" => qa_owner,
      "builder" => builder,
      "excluded_builder" => builder_excluded? ? builder : nil,
      "candidates" => candidate_slugs,
      "reviewers" => [seat(heavy, needs, "heavy"), seat(light, needs, "light")],
      "ranked" => ordered.map { |c| ranked_view(c) }
    }
  end

  private

  attr_reader :task, :qa_owner, :logger, :random

  # The full reviewer pool. A seam (returns POOL) so tests can shrink it to
  # exercise the too-few-candidates fallback without mutating the frozen constant.
  def pool
    POOL
  end

  # A STABLE integer seed derived from the task identity AND the two exclusions
  # that set the candidate pool — the QA owner and the excluded builder. CRC32 of
  # the key gives a fixed 32-bit seed, so any process selecting for the same task
  # over the SAME post-exclusion pool rolls the same tiebreak (the basis for the
  # CLI preview matching the recorded pick). Folding the excluded builder in keeps
  # two passes that exclude DIFFERENT builders (e.g. an in-memory CLI task vs the
  # persisted recorder) from sharing a seed over different pools, which would
  # diverge. A slug-less in-memory stand-in falls back to a constant key (still
  # reproducible).
  def seed_for(task, qa_owner, excluded_builder)
    Zlib.crc32("#{task.try(:slug)}:#{qa_owner}:#{excluded_builder}")
  end

  # The selectable pool — the five souls minus the QA owner (no self-gating) and
  # minus the builder (a soul never reviews their own work). The builder drop is
  # skipped when it would leave too few candidates (#builder_excluded?), so a
  # heavy+light pair is always returnable.
  def candidate_slugs
    base = pool - [qa_owner]
    builder_excluded? ? base - [builder] : base
  end

  # Who built this task: the explicit override, else devops.built_by (stamped from
  # the build-claim actor — works for the CLI's in-memory task built from board
  # JSON), else the actor on the latest `→ building` TaskEvent (persisted tasks
  # only). nil when the builder can't be determined → selection degrades to
  # domain-only (QA-owner exclusion still applies). Memoized (the event lookup
  # can hit the DB).
  def builder
    return @builder if defined?(@builder)

    @builder = (@builder_override || devops_built_by || building_event_actor).to_s.strip.presence
  end

  # True when the builder is a real selectable candidate — present, in the pool,
  # and not the QA owner (who's already excluded). The PRECONDITION for actually
  # excluding them: only a candidate can be removed. A known-but-non-pool builder
  # (a soul not seeded into POOL, or one equal to the QA owner) is NOT a candidate,
  # so "excluding" it would remove nobody — the audit must not report that as an
  # exclusion. Memoized.
  def builder_candidate?
    return @builder_candidate if defined?(@builder_candidate)

    @builder_candidate = builder.present? && (pool - [qa_owner]).include?(builder)
  end

  # True only when the builder IS a candidate (#builder_candidate?) and is actually
  # removed from the pool. False when the builder is unknown, isn't a candidate
  # (not in POOL, or is the QA owner — already out), or when removing it would drop
  # the candidate count below MIN_CANDIDATES — then the builder is KEPT and the
  # decision/log flags it. Memoized.
  def builder_excluded?
    return @builder_excluded if defined?(@builder_excluded)

    @builder_excluded =
      builder_candidate? && (pool - [qa_owner] - [builder]).size >= MIN_CANDIDATES
  end

  def devops_built_by
    task.respond_to?(:devops_built_by) ? task.devops_built_by.to_s.strip.presence : nil
  end

  # The actor on the most recent `→ building` transition — the build claim. Only
  # for a persisted task (the CLI's in-memory stand-in has no events). Any lookup
  # error degrades to nil so selection never depends on the events being readable.
  def building_event_actor
    return nil unless task.respond_to?(:task_events) && task.try(:persisted?)

    task.task_events.where(to_stage: "building").where.not(actor: [nil, ""])
        .order(:occurred_at, :id).last&.actor.to_s.strip.presence
  rescue StandardError
    nil
  end

  # The domains this change needs reviewed: its shape's domains, plus any pulled
  # in by its risk tags, plus any from the repos it touches. Empty for an
  # unknown/blank shape with no risk tags or mapped repos — then every candidate
  # scores 0 and the logged random tiebreak decides the pair.
  def needed_domains
    (Array(SHAPE_DOMAINS[task_shape]) +
     task_risk_tags.filter_map { |tag| RISK_DOMAINS[tag.to_s] } +
     task_repositories.flat_map { |repo| Array(REPO_DOMAINS[repo.to_s]) }).uniq
  end

  # Task input readers — guarded so an in-memory / non-Task stand-in (the CLI
  # builds one from board JSON) still works.
  def task_shape
    task.respond_to?(:devops_shape) ? task.devops_shape : nil
  end

  def task_risk_tags
    task.respond_to?(:devops_risk_tags) ? Array(task.devops_risk_tags) : []
  end

  def task_repositories
    task.respond_to?(:devops_repositories) ? Array(task.devops_repositories) : []
  end

  # Candidates scored + ordered best-first: domain fit (desc), then review_weight
  # (desc), then a per-candidate random roll. The roll is the LOGGED tiebreak.
  def ranked
    needs = needed_domains
    scored = candidate_slugs.map do |slug|
      domains = reviewer_domains(slug)
      { slug: slug, fit: (needs & domains).size, weight: reviewer_weight(slug),
        roll: random.rand, domains: domains }
    end
    ordered = scored.sort_by { |c| [-c[:fit], -c[:weight], c[:roll]] }
    log_tiebreak(needs, ordered)
    ordered
  end

  def pick_two
    ranked.first(2)
  end

  # HEAVY = the heavier seat (higher review_weight) for the deep review; tie →
  # better domain fit; tie → the logged random roll. LIGHT = the other.
  def split_heavy_light(pair)
    pair.sort_by { |c| [-c[:weight], -c[:fit], c[:roll]] }
  end

  # A chosen-seat view for #decision: who, at what depth, and which of the needed
  # domains they actually cover.
  def seat(candidate, needs, weight)
    {
      "slug" => candidate[:slug],
      "weight" => weight,
      "domains" => candidate[:domains],
      "matched" => (needs & candidate[:domains]),
      "fit" => candidate[:fit],
      "roll" => candidate[:roll].round(4)
    }
  end

  # A ranked-candidate view for #decision — the per-candidate roll + fit that made
  # the tiebreak auditable.
  def ranked_view(candidate)
    {
      "slug" => candidate[:slug],
      "fit" => candidate[:fit],
      "weight" => candidate[:weight],
      "roll" => candidate[:roll].round(4)
    }
  end

  def reviewer_domains(slug)
    list = agent_meta(slug)["domains"]
    list.is_a?(Array) && list.any? ? list.map(&:to_s) : Array(DEFAULT_DOMAINS[slug])
  end

  # Numeric review weight for a slug. Understands the seeded "heavy"/"light"
  # LABELS (via WEIGHT_LABELS — so the label drives the heavy seat instead of
  # silently becoming 0.0), a Numeric or numeric String (its own value), and a
  # missing/unknown value (the neutral default — never 0.0, which would sink a
  # reviewer below every default-weighted peer).
  def reviewer_weight(slug)
    raw = agent_meta(slug)["review_weight"]
    case raw
    when nil     then DEFAULT_REVIEW_WEIGHT
    when Numeric then raw.to_f
    else
      label = raw.to_s.strip.downcase
      # Only a FULLY numeric string is read as its value — a stray "12abc" must
      # NOT slip through as 12.0 (String#to_f would truncate it silently); it
      # falls back to the neutral default like any unknown label.
      WEIGHT_LABELS.fetch(label) { label.match?(/\A[-+]?\d+(?:\.\d+)?\z/) ? label.to_f : DEFAULT_REVIEW_WEIGHT }
    end
  end

  # Agent.metadata for a slug (memoized). A missing row / any lookup error
  # degrades to {} so selection never depends on the souls being seeded.
  def agent_meta(slug)
    (@agent_meta ||= {})[slug] ||= (Agent.find_by(slug: slug)&.metadata || {})
  rescue StandardError
    {}
  end

  # Emit the auditable tiebreak trail — the random rolls + the resulting ranking
  # and chosen pair — so review spread is reviewable after the fact (§1.2).
  def log_tiebreak(needs, ordered)
    chosen = ordered.first(2).map { |c| c[:slug] }
    logger.info(
      "[reviewer-selector] task=#{task.try(:slug)} needs=#{needs.join('/').presence || '-'} " \
      "excluded=#{qa_owner} builder=#{builder_log_token} " \
      "rolls=#{ordered.map { |c| "#{c[:slug]}:#{c[:roll].round(4)}" }.join(',')} " \
      "ranked=#{ordered.map { |c| "#{c[:slug]}(fit#{c[:fit]},w#{c[:weight]})" }.join('>')} " \
      "chosen=#{chosen.join('+')}"
    )
  end

  # The builder, annotated for the audit log: "-" when unknown,
  # "<slug>(excluded)" when removed from the pool, "<slug>(kept:too-few)" when a
  # POOL builder is kept because excluding it would leave too few candidates, or
  # "<slug>(not-a-candidate)" when a known builder isn't in the selectable pool
  # (not seeded into POOL, or is the QA owner) — so there was nothing to exclude.
  def builder_log_token
    return "-" if builder.blank?
    return "#{builder}(not-a-candidate)" unless builder_candidate?

    "#{builder}(#{builder_excluded? ? 'excluded' : 'kept:too-few'})"
  end
end
