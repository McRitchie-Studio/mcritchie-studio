# Picks the reviewer pair for a submitted task's PR under the Carl-owns-review
# model (docs/agents/agents/carl/sops/pr-review.md). There is no Avi supervisor
# and no domain-fit contest for the deep seat: **Carl is the STANDING PRIMARY** —
# the Lead Architect, deep reviewer, and OWNER of every PR review. The selection
# here only chooses the LIGHT (the focused second read): a domain-fit pick from
# the specialist pool {Shannon=UI · Jasper=Web3 · Steffon=DevOps/Platform ·
# Alex=Documentation}. Carl is no longer a pool pick — he sits above it as the
# fixed primary.
#
# The LIGHT is chosen by DOMAIN FIT (the task's shape + repositories + risk tags →
# the specialist whose domains cover the change) with a LOGGED, SEEDED-PER-TASK
# tiebreak, so the second read spreads across the specialists instead of always
# landing on the same soul. The pair is stamped 1 PRIMARY (Carl) / 1 LIGHT (the
# specialist); the two role NAMES come from the single vocabulary
# (config/devops_vocabulary.yml → reviewer_roles) via .primary_role / .light_role
# so the role this stamps can't drift from the SOP + the docs.
#
# The tiebreak RNG is seeded per-task by default (see #seed_for), so the LIGHT
# pick is REPRODUCIBLE across processes: `bin/reviewer-select` (.decision) and the
# avatars recorder in Task (.select) compute it independently, and the seed makes
# both roll identically — the CLI preview always matches the recorded pick, even
# on a genuine tie. Different tasks still spread the picks.
#
# CARL YIELDS THE PRIMARY SEAT ONLY to the hard "no self-review" rule: if Carl
# BUILT the task (devops.built_by == carl) — or a caller names Carl the qa_owner —
# he reviews nothing, and the standing-primary convenience gives way to a
# domain-fit pair drawn entirely from the specialist pool. Self-review integrity
# outranks the standing-primary policy.
#
# The specialist pool is {shannon=UI · jasper=Web3 · steffon=DevOps/Platform ·
# alex=Documentation}. The QA owner (Avi by default — after the 2026-07-22 reslot he
# owns qa-release: the accepted→release sweep + the QA deploy that flips members
# `assembled`) is EXCLUDED as a LIGHT so one soul never both reviews AND QAs the same
# change — "no self-gating". Avi isn't in the specialist pool, so his default
# exclusion is a formal safeguard; pass a different `qa_owner:` (e.g. a specialist)
# and that soul is dropped from the light pool for this task.
#
# The BUILDER is excluded from the LIGHT seat too — a soul shouldn't review their
# own work. Who built the task is read from devops.built_by (stamped from the
# build-claim actor when it resolves to a soul slug — see Task#stamp_builder) and,
# for a persisted task, falls back to the actor on the latest `→ building`
# TaskEvent; pass `builder:` to override. A builder who isn't a specialist (Carl,
# a non-pool soul, or the QA owner) excludes nobody from the light pool. If
# excluding a specialist builder would leave too few light candidates the builder
# is KEPT (the decision/log flags it) so a pair is always returned.
#
# BUSY souls are excluded from the LIGHT seat too — specialists currently
# mid-build or mid-review on OTHER in-flight tasks shouldn't be handed a second
# read while they're heads-down elsewhere. Pass `busy:` (bin/reviewer-select's
# `--busy a,b,c`, and/or its board query of agents on stage=building tasks). Like
# the builder, the busy drop YIELDS rather than starve: if removing the builder +
# QA owner + every busy soul would leave too few candidates, the least-bad (best
# domain fit) busy souls are KEPT eligible (the decision/log flags them) so a pair
# is always returned.
#
# Reads each specialist's Agent.metadata["domains"] + ["review_weight"]; DEGRADES
# GRACEFULLY to built-in defaults when the Agent row or those keys are absent, so
# selection works even before the reviewer souls are seeded.
#
# `bin/reviewer-select <task>` is the CLI wrapper a review session runs to preview
# the pair + the auditable tiebreak from `.explain`.
require "zlib"

class ReviewerSelector
  # The full senior soul pool (slugs). Carl is the standing primary (removed from
  # the specialist draw below); the other four are the LIGHT specialists.
  POOL = %w[shannon carl jasper steffon alex].freeze

  # Carl — the Lead Architect. He owns EVERY PR review as the STANDING PRIMARY
  # (deep review + owner), so he is never a light-pool pick.
  STANDING_PRIMARY = "carl"

  # The soul who runs qa-release — the accepted→release sweep + the QA deploy at the
  # `assembled` step — excluded from the light pool by default so a reviewer never
  # gates their own QA (no self-gating). After the 2026-07-22 reslot this is AVI (he
  # owns qa-release); Steffon moved to production-deploy (the ship) and rejoined the
  # light specialist pool as the DevOps/Platform second read.
  DEFAULT_QA_OWNER = "avi"

  # The two reviewer-role NAMES, sourced from the single vocabulary
  # (config/devops_vocabulary.yml → reviewer_roles) so the role this selector
  # stamps stays in lockstep with the SOP + the docs — rename a role in the YAML
  # and it flows here in one edit. Order is the convention: the FIRST role is the
  # deep/accountable seat (primary), the SECOND the focused second pass (light).
  # Degrades to the built-in pair if the YAML can't be read, so selection never
  # depends on the config loading.
  ROLE_FALLBACK = %w[primary light].freeze

  def self.reviewer_roles
    names = Devops::Vocabulary.reviewer_roles.keys.map(&:to_s)
    names.size >= 2 ? names : ROLE_FALLBACK
  rescue StandardError
    ROLE_FALLBACK
  end

  # The deep/accountable seat's role name (the "primary" reviewer — Carl).
  def self.primary_role = reviewer_roles.first

  # The focused second-pass seat's role name (the "light" reviewer — a specialist).
  def self.light_role = reviewer_roles.last

  # Fallback domain tags per soul when an Agent row has no metadata["domains"].
  # Keep aligned with the seeded `domains` in db/seeds/02_agents.rb.
  DEFAULT_DOMAINS = {
    "shannon" => %w[ui],
    "carl"    => %w[backend],
    "jasper"  => %w[web3 onchain],
    "steffon" => %w[devops platform],
    "alex"    => %w[docs documentation]
  }.freeze

  # Neutral weight when an Agent row has no metadata["review_weight"].
  DEFAULT_REVIEW_WEIGHT = 1.0

  # The seeded review_weight LABELS → their numeric weight. Under the standing-Carl
  # model this only orders the LIGHT specialists on a fit tie (the primary seat no
  # longer depends on it). A bare String#to_f would silently zero every label
  # ("heavy".to_f == 0.0); mapping the labels here keeps numeric weights (tests,
  # future tuning) and legacy "heavy"/"light" label rows both working.
  WEIGHT_LABELS = { "heavy" => 2.0, "light" => 1.0 }.freeze

  # The task's shape → the review domains that change needs covered (drives the
  # LIGHT specialist's domain fit).
  SHAPE_DOMAINS = {
    "ui-only"          => %w[ui],
    "ui+db"            => %w[ui backend],
    "backend"          => %w[backend],
    "library"          => %w[backend],
    "onchain"          => %w[web3 onchain],
    "onchain-vertical" => %w[web3 onchain ui backend],
    # A documentation-only change (SOP / runbook / operating-model / README) needs
    # the pool's Documentation seat — Alex, whose seeded domains carry both `docs`
    # and `documentation`. Both tokens map here so a doc-shaped task fits Alex
    # (fit 2) and nobody else (fit 0), landing him the LIGHT seat. Read by BOTH the
    # CLI preview (.decision) and the recorder (.select), so they stay reproducible.
    "docs"             => %w[docs documentation]
  }.freeze

  # A risk tag → the domain whose specialist should weigh in as the light (deepens
  # the fit for risk-bearing work — e.g. a `solana` tag pulls Web3 in even on a
  # backend shape, where Carl already owns the deep read).
  RISK_DOMAINS = {
    "solana"    => "web3",
    "onchain"   => "web3",
    "payment"   => "backend",
    "migration" => "backend",
    "auth"      => "backend",
    "ui"        => "ui",
    "docs"      => "docs"
  }.freeze

  # A repo a task touches → the domain whose specialist should weigh in as the
  # light. The on-chain repos carry a strong Web3 signal the change's shape alone
  # can miss (e.g. a `backend` Ruby change inside solana-studio still wants
  # Jasper's eyes). ADDITIVE only — an unmapped repo contributes nothing.
  REPO_DOMAINS = {
    "turf-vault"    => %w[web3 onchain],
    "solana-studio" => %w[web3 onchain]
  }.freeze

  # The TaskEvent.metadata["reviewers"] payload: [{ "slug" =>, "weight" => },…].
  def self.select(task, **opts)
    new(task, **opts).reviewers
  end

  # The full, auditable decision record for the CLI (bin/reviewer-select): the
  # chosen pair (primary/light) PLUS the inputs, each reviewer's matched domains,
  # the excluded QA owner, and the per-candidate rolls + ranking — produced in ONE
  # ranked pass (one roll set) so what the CLI prints is exactly what was picked.
  # `.select` stays the slim canonical pick the model records.
  def self.explain(task, **opts)
    new(task, **opts).decision
  end

  # `builder:` overrides who built the task (else it's derived from the task —
  # see #builder). Pass it when the caller already knows the build agent.
  # `busy:` is a set of souls currently mid-build / mid-review on OTHER in-flight
  # tasks; they're excluded from the LIGHT pool too, so the second read never lands
  # on a specialist who's already heads-down elsewhere — UNLESS excluding them
  # would starve the pool below the light floor, in which case the least-bad busy
  # souls are KEPT back (see #excluded_busy), mirroring the builder keep rule.
  def initialize(task, qa_owner: DEFAULT_QA_OWNER, builder: nil, busy: [], logger: nil, random: nil)
    @task = task
    @qa_owner = qa_owner.to_s
    @builder_override = builder.to_s.strip.presence
    @busy = Array(busy).map { |s| s.to_s.strip }.reject(&:empty?).uniq
    @logger = logger || Rails.logger
    # Default the tiebreak RNG to a STABLE per-task seed. The default LIGHT pick
    # must be reproducible across processes: bin/reviewer-select prints `.decision`
    # while the avatars recorder in Task computes `.select` INDEPENDENTLY, so on a
    # genuine fit+weight tie a fresh process RNG let them diverge — one pair spawned,
    # another recorded. Seeding from the task's own identity (+ the excluded QA
    # owner AND excluded builder, which set the light pool) makes both passes roll
    # identically over the SAME post-exclusion pool, while different tasks still
    # spread the picks. Tests pass an explicit `random:` to pin a scenario.
    @random = random || Random.new(seed_for(@task, @qa_owner, builder_excluded? ? builder : nil, excluded_busy))
  end

  # Exactly two entries — [{ "slug" => carl, "weight" => "primary" }, { … "light" }]
  # — string-keyed so it serializes straight into the jsonb event metadata. The
  # role names come from the vocabulary (self.class.primary_role / .light_role).
  def reviewers
    primary, light = pair
    [
      { "slug" => primary[:slug], "weight" => self.class.primary_role },
      { "slug" => light[:slug], "weight" => self.class.light_role }
    ]
  end

  # The auditable selection detail behind #reviewers (see .explain) — string-keyed
  # so it serializes straight to JSON. One ranked pass (memoized #ranked), so the
  # rolls reported here are the rolls the light pick was made on.
  def decision
    needs = needed_domains
    primary, light = pair
    {
      "task" => task.try(:slug),
      "shape" => task_shape,
      "repositories" => task_repositories,
      "risk_tags" => task_risk_tags,
      "needed_domains" => needs,
      "standing_primary" => carl_primary? ? STANDING_PRIMARY : nil,
      "excluded_qa_owner" => qa_owner,
      "builder" => builder,
      "excluded_builder" => builder_excluded? ? builder : nil,
      "builder_candidate" => builder_candidate?,
      "busy" => busy,
      "excluded_busy" => excluded_busy,
      "kept_busy" => kept_busy,
      "candidates" => candidate_slugs,
      "reviewers" => [seat(primary, needs, self.class.primary_role), seat(light, needs, self.class.light_role)],
      "ranked" => ranked.map { |c| ranked_view(c) }
    }
  end

  private

  attr_reader :task, :qa_owner, :busy, :logger, :random

  # The full soul pool. A seam (returns POOL) so tests can shrink it to exercise
  # the too-few-candidates fallback without mutating the frozen constant.
  def pool
    POOL
  end

  # The LIGHT specialist pool — the full pool minus Carl (the standing primary).
  def light_pool
    pool - [STANDING_PRIMARY]
  end

  # True when Carl takes the standing PRIMARY seat. He yields it ONLY to the hard
  # no-self-review rule: he built the task, or a caller named him the qa_owner.
  # (Busy does NOT unseat Carl — the review model spins a FRESH Carl per PR, so
  # "Carl is busy elsewhere" never applies to the primary seat.)
  def carl_primary?
    STANDING_PRIMARY != qa_owner && STANDING_PRIMARY != builder
  end

  # The floor of LIGHT candidates a selection needs: 1 when Carl takes the standing
  # primary seat (only the light is drawn from the pool), 2 when Carl is out (he
  # built it, or is the QA owner) and BOTH seats are domain picks. The builder/busy
  # drops yield rather than fall below this.
  def min_candidates
    carl_primary? ? 1 : 2
  end

  # The chosen [primary, light] candidate pair. In the normal case Carl is the
  # fixed primary and the light is the best-fit specialist; when Carl has yielded
  # (self-review), BOTH seats are the top domain-fit specialists. Memoized so the
  # decision's pair and its ranked view agree.
  def pair
    @pair ||= begin
      lights = ranked
      carl_primary? ? [carl_candidate, lights.first] : lights.first(2)
    end
  end

  # The standing-primary candidate view (Carl). Not part of the light ranking, so
  # it carries a fixed roll of 0.0 — he is chosen deterministically, not rolled.
  def carl_candidate
    build_candidate(STANDING_PRIMARY, roll: 0.0)
  end

  def build_candidate(slug, roll:)
    domains = reviewer_domains(slug)
    { slug: slug, fit: (needed_domains & domains).size, weight: reviewer_weight(slug),
      roll: roll, domains: domains }
  end

  # A STABLE integer seed derived from the task identity AND the two exclusions
  # that set the light pool — the QA owner and the excluded builder. CRC32 of the
  # key gives a fixed 32-bit seed, so any process selecting for the same task over
  # the SAME post-exclusion pool rolls the same tiebreak (the basis for the CLI
  # preview matching the recorded pick). Folding the excluded builder in keeps two
  # passes that exclude DIFFERENT builders from sharing a seed over different pools.
  # A slug-less in-memory stand-in falls back to a constant key (still reproducible).
  def seed_for(task, qa_owner, excluded_builder, excluded_busy_list = [])
    key = "#{task.try(:slug)}:#{qa_owner}:#{excluded_builder}"
    # Fold the excluded busy souls in (only when present, so the no-busy seed is
    # byte-for-byte the historical one and the default pick never shifts).
    key += ":#{excluded_busy_list.sort.join(',')}" if excluded_busy_list.any?
    Zlib.crc32(key)
  end

  # The selectable LIGHT pool — the four specialists minus the QA owner (no
  # self-gating), minus the builder (a soul never reviews their own work), minus
  # the busy souls (mid-build / mid-review elsewhere). Each drop yields rather than
  # starve: the builder is kept when removing it would leave too few candidates
  # (#builder_excluded?), and the busy filter keeps the least-bad busy souls back
  # the same way (#excluded_busy).
  def candidate_slugs
    busy_base - excluded_busy
  end

  # The light pool AFTER the QA-owner + builder drops but BEFORE the busy filter —
  # the floor the busy filter protects.
  def busy_base
    return @busy_base if defined?(@busy_base)

    base = light_pool - [qa_owner]
    @busy_base = builder_excluded? ? base - [builder] : base
  end

  # The busy souls actually removed. Only a busy soul that's a real light candidate
  # (in busy_base) is removable; removing every removable busy soul can starve the
  # pool, so the filter removes the LEAST useful ones first (worst domain fit, then
  # a stable slug order) and STOPS once the remaining candidate count would fall
  # below #min_candidates — keeping the best-fitting (least-bad) busy souls eligible
  # (#kept_busy). Memoized; pure of the tiebreak RNG, so it's safe to compute for
  # the seed.
  def excluded_busy
    return @excluded_busy if defined?(@excluded_busy)

    removable = busy & busy_base
    room = [busy_base.size - min_candidates, 0].max
    drop = [removable.size, room].min
    @excluded_busy = removable.sort_by { |slug| [busy_domain_fit(slug), slug] }.first(drop)
  end

  # Busy souls that WERE candidates but had to stay eligible to keep a formable
  # pair (the keep-rather-than-starve remainder). Empty in the common case.
  def kept_busy
    (busy & busy_base) - excluded_busy
  end

  # A busy soul's domain fit — used only to order which busy souls to drop first
  # (worst fit) when the pool can't afford to exclude them all.
  def busy_domain_fit(slug)
    (needed_domains & reviewer_domains(slug)).size
  end

  # Who built this task: the explicit override, else devops.built_by (stamped from
  # the build-claim actor — works for the CLI's in-memory task built from board
  # JSON), else the actor on the latest `→ building` TaskEvent (persisted tasks
  # only). nil when the builder can't be determined. Memoized (the event lookup
  # can hit the DB).
  def builder
    return @builder if defined?(@builder)

    @builder = (@builder_override || devops_built_by || building_event_actor).to_s.strip.presence
  end

  # True when the builder is a real selectable LIGHT candidate — present, in the
  # light pool, and not the QA owner (who's already excluded). The PRECONDITION for
  # actually excluding them: only a candidate can be removed. Carl-the-builder is
  # NOT a light candidate (he's the standing primary, who has already yielded the
  # seat via #carl_primary?), a known-but-non-pool builder is NOT a candidate, and
  # the QA owner is already out — so "excluding" any of those removes nobody, and
  # the audit must not report an exclusion. Memoized.
  def builder_candidate?
    return @builder_candidate if defined?(@builder_candidate)

    @builder_candidate = builder.present? && (light_pool - [qa_owner]).include?(builder)
  end

  # True only when the builder IS a light candidate (#builder_candidate?) and is
  # actually removed from the pool. False when the builder is unknown, isn't a
  # candidate (Carl, not a specialist, or the QA owner), or when removing it would
  # drop the light count below #min_candidates — then the builder is KEPT and the
  # decision/log flags it. Memoized.
  def builder_excluded?
    return @builder_excluded if defined?(@builder_excluded)

    @builder_excluded =
      builder_candidate? && (light_pool - [qa_owner] - [builder]).size >= min_candidates
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

  # The domains this change needs reviewed: its shape's domains, plus any pulled in
  # by its risk tags, plus any from the repos it touches. Empty for an unknown/blank
  # shape with no risk tags or mapped repos — then every specialist scores 0 and the
  # logged random tiebreak decides the light.
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

  # The LIGHT specialists scored + ordered best-first: domain fit (desc), then
  # review_weight (desc), then a per-candidate random roll. The roll is the LOGGED
  # tiebreak. Memoized so the pair and the decision's ranked view share one roll set.
  def ranked
    @ranked ||= begin
      needs = needed_domains
      scored = candidate_slugs.map { |slug| build_candidate(slug, roll: random.rand) }
      ordered = scored.sort_by { |c| [-c[:fit], -c[:weight], c[:roll]] }
      log_tiebreak(needs, ordered)
      ordered
    end
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
  # the light tiebreak auditable.
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

  # Numeric review weight for a slug. Understands the seeded "heavy"/"light" LABELS
  # (via WEIGHT_LABELS — so the label isn't silently zeroed by String#to_f), a
  # Numeric or numeric String (its own value), and a missing/unknown value (the
  # neutral default — never 0.0, which would sink a specialist below every
  # default-weighted peer).
  def reviewer_weight(slug)
    raw = agent_meta(slug)["review_weight"]
    case raw
    when nil     then DEFAULT_REVIEW_WEIGHT
    when Numeric then raw.to_f
    else
      label = raw.to_s.strip.downcase
      # Only a FULLY numeric string is read as its value — a stray "12abc" must NOT
      # slip through as 12.0 (String#to_f would truncate it silently); it falls back
      # to the neutral default like any unknown label.
      WEIGHT_LABELS.fetch(label) { label.match?(/\A[-+]?\d+(?:\.\d+)?\z/) ? label.to_f : DEFAULT_REVIEW_WEIGHT }
    end
  end

  # Agent.metadata for a slug (memoized). A missing row / any lookup error degrades
  # to {} so selection never depends on the souls being seeded.
  def agent_meta(slug)
    (@agent_meta ||= {})[slug] ||= (Agent.find_by(slug: slug)&.metadata || {})
  rescue StandardError
    {}
  end

  # Emit the auditable tiebreak trail — the standing primary, the LIGHT rolls + the
  # resulting ranking, and the chosen pair — so review spread is reviewable after
  # the fact. `chosen` is computed inline from `ordered` (never via #pair) to avoid
  # re-entering #ranked while it memoizes.
  def log_tiebreak(needs, ordered)
    chosen = carl_primary? ? [STANDING_PRIMARY, ordered.first&.dig(:slug)] : ordered.first(2).map { |c| c[:slug] }
    logger.info(
      "[reviewer-selector] task=#{task.try(:slug)} needs=#{needs.join('/').presence || '-'} " \
      "primary=#{carl_primary? ? STANDING_PRIMARY : "#{ordered.first&.dig(:slug)}(yield)"} " \
      "excluded=#{qa_owner} builder=#{builder_log_token} busy=#{busy_log_token} " \
      "rolls=#{ordered.map { |c| "#{c[:slug]}:#{c[:roll].round(4)}" }.join(',')} " \
      "ranked=#{ordered.map { |c| "#{c[:slug]}(fit#{c[:fit]},w#{c[:weight]})" }.join('>')} " \
      "chosen=#{chosen.compact.join('+')}"
    )
  end

  # The builder, annotated for the audit log: "-" when unknown, "<slug>(excluded)"
  # when removed from the light pool, "<slug>(kept:too-few)" when a specialist
  # builder is kept because excluding it would leave too few candidates, or
  # "<slug>(not-a-candidate)" when a known builder isn't a light candidate (Carl,
  # a non-pool soul, or the QA owner) — so there was nothing to exclude.
  def builder_log_token
    return "-" if builder.blank?
    return "#{builder}(not-a-candidate)" unless builder_candidate?

    "#{builder}(#{builder_excluded? ? 'excluded' : 'kept:too-few'})"
  end

  # The busy souls, annotated for the audit log: "-" when none were passed, else the
  # excluded ones, with any kept-back (starve-guard) souls flagged "(kept)".
  def busy_log_token
    return "-" if busy.empty?

    (excluded_busy + kept_busy.map { |s| "#{s}(kept)" }).join(",").presence || "-"
  end
end
