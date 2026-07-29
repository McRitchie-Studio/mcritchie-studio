class News < ApplicationRecord
  # Board rank read-model (studio-engine board primitive). Supplies `reposition!`
  # (used by the shared Studio::Board::Reorderable reorder action), `board_next_position`,
  # the `board_ordered` scope, and the `set_initial_position` genesis seed wired below.
  # `board_zone_attr` defaults to :stage — a card ranks within its own column, 100-spaced.
  include Studio::Board::Rankable

  STAGES = %w[new reviewed processed refined concluded archived].freeze

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :stage, inclusion: { in: STAGES }

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
  def review!
    update!(stage: "reviewed")
  end

  def process_news!
    update!(stage: "processed")
  end

  def refine!
    update!(stage: "refined")
  end

  def conclude!
    update!(stage: "concluded")
  end

  def archive!
    update!(stage: "archived")
  end

  private

  def set_stage_timestamp
    case stage
    when "reviewed"  then self.reviewed_at = Time.current
    when "processed" then self.processed_at = Time.current
    when "refined"   then self.refined_at = Time.current
    when "concluded" then self.concluded_at = Time.current
    when "archived"  then self.archived_at = Time.current
    end
    # On a stage move, bump the card to the top of its new column (zone-max + 100),
    # via the concern's shared 100-gap helper. set_initial_position (the genesis seed)
    # comes from Studio::Board::Rankable; the create-time branch is guarded out here.
    self.position = self.class.board_next_position(stage) unless new_record?
  end

  def generate_slug
    self.slug ||= "news-#{SecureRandom.hex(6)}"
  end
end
