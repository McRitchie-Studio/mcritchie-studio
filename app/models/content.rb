class Content < ApplicationRecord
  # Board rank read-model (studio-engine board primitive). Supplies `reposition!`
  # (used by the shared Studio::Board::Reorderable reorder action), `board_next_position`,
  # the `board_ordered` scope, and the `set_initial_position` genesis seed wired below.
  # `board_zone_attr` defaults to :stage — a card ranks within its own column, 100-spaced.
  include Studio::Board::Rankable

  STAGES = %w[idea hook script assets assembly posted reviewed].freeze
  WORKFLOWS = %w[video starter_post_x starter_post_tiktok_offense starter_post_tiktok_defense game_recap rapper_replace].freeze

  TIKTOK_WORKFLOWS = %w[starter_post_tiktok_offense starter_post_tiktok_defense].freeze

  # A recap of one finished game. `team_slug` is the WINNER and `rival_team_slug`
  # the loser — the same two columns the other workflows use for "us" and "them",
  # so the existing team-colour and hashtag lookups keep working unchanged.
  GAME_RECAP_WORKFLOW = "game_recap".freeze

  # The first content STYLE: a qualifying duo swapped into a music-video shot.
  # Its gate is the three image artifacts, which a human must look at before
  # any video is made.
  RAPPER_REPLACE_WORKFLOW = "rapper_replace".freeze

  def tiktok_workflow?
    TIKTOK_WORKFLOWS.include?(workflow)
  end

  def game_recap?
    workflow == GAME_RECAP_WORKFLOW
  end

  def rapper_replace?
    workflow == RAPPER_REPLACE_WORKFLOW
  end

  def artifacts_approved? = artifacts_approved_at.present?

  # The colorway we BELIEVE the winner wore, from the only signal the feed
  # gives us: home or away. It is a guess and is labelled one — NFL teams wear
  # alternates and throwbacks, and a wrong jersey is the artifact defect that
  # matters most. The operator confirms or overrides it at the inspection gate,
  # which is the same moment they are already looking at the images.
  def guessed_colorway
    return nil if game_facts.blank?

    winner = game_facts["winner_slug"]
    return nil if winner.blank?

    winner == game_facts["away_team_slug"] ? "white" : "primary"
  end

  def effective_colorway
    colorway.presence || guessed_colorway
  end

  def lineup_side
    case workflow
    when "starter_post_tiktok_offense" then "offense"
    when "starter_post_tiktok_defense" then "defense"
    end
  end

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :stage, inclusion: { in: STAGES }
  validates :workflow, inclusion: { in: WORKFLOWS }

  belongs_to :source_news, class_name: "News", foreign_key: :source_news_slug, primary_key: :slug, optional: true
  belongs_to :rival_team, class_name: "Team", foreign_key: :rival_team_slug, primary_key: :slug, optional: true
  belongs_to :team, class_name: "Team", foreign_key: :team_slug, primary_key: :slug, optional: true

  # The winning and losing sides, named for what they are. `team`/`rival_team`
  # stay as the storage; these are what a caller should read, so nobody has to
  # remember which column holds which side. Declared AFTER the associations —
  # `alias_method` resolves at class-definition time, so above them it raises
  # `undefined method 'team' for class Content`.
  alias_method :winning_team, :team
  alias_method :losing_team, :rival_team

  before_validation :generate_slug, on: :create
  before_create :set_initial_position
  before_save :set_stage_timestamp, if: :stage_changed?

  # --- the agent claim ---------------------------------------------------
  #
  # Non-deterministic steps (the script, the scenes, the caption) are written by
  # a SOUL during an SOP, using its own inference, rather than by an in-app call
  # to the Anthropic API. The board is already the queue — a Content sitting at
  # `idea` IS a pending work item — so a claim is the only primitive that was
  # missing: without it, two sessions draining the same queue both script the
  # same game and produce two different takes.
  #
  # The lease expires so a session that dies mid-SOP does not strand the card.
  AGENT_CLAIM_LEASE = 30.minutes

  # Free to claim: never claimed, or claimed long enough ago that the holder is
  # presumed gone.
  scope :claimable_by_agent, ->(now: Time.current) {
    where(claimed_at: nil).or(where(claimed_at: ...(now - AGENT_CLAIM_LEASE)))
  }

  ClaimResult = Struct.new(:content, :reason, keyword_init: true) do
    def claimed? = reason == "claimed"
  end

  # The ATOMIC pop. The server picks WHICH content, exactly as
  # `Task.claim_next_review` does, so the decision cannot drift between callers.
  #
  # `FOR UPDATE SKIP LOCKED` is what makes it safe under concurrency: a row a
  # racer is already inside is skipped rather than waited on, so two agents
  # draining the queue together never block and never collide.
  #
  # An empty pop is a NORMAL outcome, not an error — the caller idles.
  def self.claim_next_for_agent(session:, agent: nil, stage: "idea", workflow: nil, now: Time.current)
    scope = claimable_by_agent(now: now).by_stage(stage)
    scope = scope.where(workflow: workflow) if workflow.present?

    slugs = scope.ordered.pluck(:slug)
    return ClaimResult.new(content: nil, reason: "none_claimable") if slugs.empty?

    slugs.each do |slug|
      claimed = transaction do
        content = claimable_by_agent(now: now).where(slug: slug).lock("FOR UPDATE SKIP LOCKED").first
        next nil unless content # a racer holds it, or it was claimed since the pluck

        content.update!(claimed_by: agent.presence || session, claim_session: session, claimed_at: now)
        ClaimResult.new(content: content, reason: "claimed")
      end
      return claimed if claimed
    end

    ClaimResult.new(content: nil, reason: "none_claimable")
  end

  def claim_expired?(now: Time.current)
    claimed_at.present? && claimed_at < now - AGENT_CLAIM_LEASE
  end

  def claim_held?(now: Time.current)
    claimed_at.present? && !claim_expired?(now: now)
  end

  # Dropping the lease is deliberately unconditional for the HOLDER and refused
  # for anyone else: a release is how a soul says "I am done or I gave up", and
  # letting a stranger release it would re-open a card someone is still writing.
  def release_claim!(session: nil)
    if session.present? && claim_session.present? && claim_session != session && claim_held?
      raise ArgumentError, "content #{slug} is held by another session"
    end

    update!(claimed_by: nil, claim_session: nil, claimed_at: nil)
  end

  scope :by_stage, ->(stage) { where(stage: stage) }
  # Board order comes from the concern (position DESC NULLS LAST, created_at DESC).
  scope :ordered, -> { board_ordered }

  def to_param
    slug
  end

  # Transition methods
  def hook!
    update!(stage: "hook")
  end

  def script!
    update!(stage: "script")
  end

  def assets!
    update!(stage: "assets")
  end

  def assemble!
    update!(stage: "assembly")
  end

  def post!
    update!(stage: "posted")
  end

  def review!
    update!(stage: "reviewed")
  end

  def archive!
    update!(stage: "idea")
  end

  private

  def set_stage_timestamp
    case stage
    when "hook"     then self.hooked_at = Time.current
    when "script"   then self.scripted_at = Time.current
    when "assets"   then self.asset_at = Time.current
    when "assembly" then self.assembled_at = Time.current
    when "posted"   then self.posted_at = Time.current
    when "reviewed" then self.reviewed_at = Time.current
    end
    # On a stage move, bump the card to the top of its new column (zone-max + 100),
    # via the concern's shared 100-gap helper. set_initial_position (the genesis seed)
    # comes from Studio::Board::Rankable; the create-time branch is guarded out here.
    self.position = self.class.board_next_position(stage) unless new_record?
  end

  def generate_slug
    self.slug ||= "content-#{SecureRandom.hex(6)}"
  end
end
