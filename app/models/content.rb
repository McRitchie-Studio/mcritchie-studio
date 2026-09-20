class Content < ApplicationRecord
  # Board rank read-model (studio-engine board primitive). Supplies `reposition!`
  # (used by the shared Studio::Board::Reorderable reorder action), `board_next_position`,
  # the `board_ordered` scope, and the `set_initial_position` genesis seed wired below.
  # `board_zone_attr` defaults to :stage — a card ranks within its own column, 100-spaced.
  include Studio::Board::Rankable

  STAGES = %w[idea hook script assets assembly posted reviewed].freeze
  WORKFLOWS = %w[video starter_post_x starter_post_tiktok_offense starter_post_tiktok_defense game_recap].freeze

  TIKTOK_WORKFLOWS = %w[starter_post_tiktok_offense starter_post_tiktok_defense].freeze

  # A recap of one finished game. `team_slug` is the WINNER and `rival_team_slug`
  # the loser — the same two columns the other workflows use for "us" and "them",
  # so the existing team-colour and hashtag lookups keep working unchanged.
  GAME_RECAP_WORKFLOW = "game_recap".freeze

  def tiktok_workflow?
    TIKTOK_WORKFLOWS.include?(workflow)
  end

  def game_recap?
    workflow == GAME_RECAP_WORKFLOW
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
