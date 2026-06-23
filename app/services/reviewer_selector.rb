# Picks the TWO senior reviewers for a submitted task's PR — Avi's "delegate
# review to two seniors" step in the redesigned Deploy workflow
# (docs/agents/system/devops-cycle-design.md §1.2). Selection is by DOMAIN FIT
# (the task's shape + risk tags → the reviewer whose domains cover the change)
# with a LOGGED random tiebreak, so reviews spread across the pool instead of
# always landing on the obvious domain owner. The pair is split 1 HEAVY (the deep
# review) / 1 LIGHT, driven by each reviewer's review_weight.
#
# The pool is {shannon=UI · carl=backend · jasper=Web3 · steffon=DevOps/Platform ·
# alex=Documentation}. The QA owner (Steffon, who QAs the assembled RC at the
# `assembled` step) is EXCLUDED so one soul never both reviews AND QAs the same
# change — "no self-gating" (§1.2). Steffon stays a valid reviewer for other PRs;
# pass a different `qa_owner:` when he isn't the one QAing this task.
#
# Reads each reviewer's Agent.metadata["domains"] + ["review_weight"]; DEGRADES
# GRACEFULLY to built-in defaults when the Agent row or those keys are absent, so
# selection works even before the reviewer souls are seeded.
class ReviewerSelector
  # The senior reviewer pool (slugs).
  POOL = %w[shannon carl jasper steffon alex].freeze

  # The soul who QAs the assembled RC at the `assembled` step — excluded from the
  # pool by default so a reviewer never gates their own QA (§1.2 "no self-gating").
  DEFAULT_QA_OWNER = "steffon"

  # Fallback domain tags per reviewer when an Agent row has no metadata["domains"].
  DEFAULT_DOMAINS = {
    "shannon" => %w[ui],
    "carl"    => %w[backend],
    "jasper"  => %w[web3 onchain],
    "steffon" => %w[devops platform],
    "alex"    => %w[docs]
  }.freeze

  # Neutral weight when an Agent row has no metadata["review_weight"].
  DEFAULT_REVIEW_WEIGHT = 1.0

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

  # The TaskEvent.metadata["reviewers"] payload: [{ "slug" =>, "weight" => },…].
  def self.select(task, **opts)
    new(task, **opts).reviewers
  end

  def initialize(task, qa_owner: DEFAULT_QA_OWNER, logger: nil, random: Random.new)
    @task = task
    @qa_owner = qa_owner.to_s
    @logger = logger || Rails.logger
    @random = random
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

  private

  attr_reader :task, :qa_owner, :logger, :random

  # The selectable pool — the five souls minus the QA owner (no self-gating).
  def candidate_slugs
    POOL - [qa_owner]
  end

  # The domains this change needs reviewed: its shape's domains plus any pulled in
  # by its risk tags. Empty for an unknown/blank shape with no risk tags — then
  # every candidate scores 0 and the logged random tiebreak decides the pair.
  def needed_domains
    shape = task.respond_to?(:devops_shape) ? task.devops_shape : nil
    risks = task.respond_to?(:devops_risk_tags) ? Array(task.devops_risk_tags) : []
    (Array(SHAPE_DOMAINS[shape]) + risks.filter_map { |tag| RISK_DOMAINS[tag.to_s] }).uniq
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

  def reviewer_domains(slug)
    list = agent_meta(slug)["domains"]
    list.is_a?(Array) && list.any? ? list.map(&:to_s) : Array(DEFAULT_DOMAINS[slug])
  end

  def reviewer_weight(slug)
    raw = agent_meta(slug)["review_weight"]
    raw.nil? ? DEFAULT_REVIEW_WEIGHT : raw.to_f
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
      "excluded=#{qa_owner} " \
      "rolls=#{ordered.map { |c| "#{c[:slug]}:#{c[:roll].round(4)}" }.join(',')} " \
      "ranked=#{ordered.map { |c| "#{c[:slug]}(fit#{c[:fit]},w#{c[:weight]})" }.join('>')} " \
      "chosen=#{chosen.join('+')}"
    )
  end
end
