# One entry in the communications record: who said what, and what was asked.
#
# TWO KINDS, ONE TABLE, because they are the same thing at different
# resolutions and separate tables would mean joining them back together on
# every read:
#
#   general — the raw stream. Transcripts, texts, messages, calls. High volume,
#             low structure; it is filed and moved past.
#   ask     — a specific request that needs work, and the reason this exists.
#
# WHY `processing` AND `key_points` BOTH EXIST. They are opposites on purpose.
# `processing` is unbounded text: the working, the reasoning, the dead ends,
# with room to breathe. `key_points` is capped per entry so the conclusion stays
# findable at a glance. Letting `processing` prose into `key_points` collapses
# the distinction and the record loses the thing it was built for — which is why
# the cap is a validation rather than a convention.
class Communication < ApplicationRecord
  KINDS = %w[general ask].freeze

  # Every mouth the record has. `other` is deliberate: an unlisted channel
  # should land as a row someone can reclassify, not be refused at the door.
  CHANNELS = %w[email fathom sms google_messages pocket slack call meeting other].freeze

  DIRECTIONS = %w[inbound outbound internal].freeze

  # Ask lifecycle. `delivered` means a deliverable URL exists and a human has
  # been handed it; `closed` means it needs nothing further.
  STATUSES = %w[open researching drafted delivered closed].freeze

  # A key point is a BULLET, not a paragraph. 200 characters is roughly two
  # lines — past that, it is `processing` content wearing a bullet's clothes.
  KEY_POINT_MAX = 200

  # Columns that belong to an ask alone. A general row carrying them means
  # something classified it wrong, and finding that later is much harder than
  # refusing it now.
  ASK_ONLY_FIELDS = %i[ask_text processing status deliverable_url due_at owner].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :channel, inclusion: { in: CHANNELS }
  validates :direction, inclusion: { in: DIRECTIONS }, allow_nil: true
  validates :external_id, uniqueness: { scope: :channel }, allow_nil: true
  validates :ask_text, presence: true, if: :ask?
  validates :status, inclusion: { in: STATUSES }, if: :ask?

  validate :key_points_are_terse
  validate :participants_are_records
  validate :access_levels_are_known
  validate :general_rows_carry_no_ask_fields

  before_validation :normalize

  scope :asks,        -> { where(kind: "ask") }
  scope :general,     -> { where(kind: "general") }
  scope :for_entity,  ->(entity) { where(entity: entity) }
  scope :on_channel,  ->(channel) { where(channel: channel) }
  scope :on_thread,   ->(key) { where(thread_key: key) }
  scope :with_status, ->(status) { where(status: status) }
  scope :open_asks,   -> { asks.where(status: %w[open researching drafted]) }
  scope :newest_first, -> { order(Arel.sql("occurred_at DESC NULLS LAST, id DESC")) }

  # The board order the operator reads: asks first, then newest first. Postgres
  # sorts false < true, so DESC puts the asks on top.
  scope :board_order, -> { order(Arel.sql("(kind = 'ask') DESC, occurred_at DESC NULLS LAST, id DESC")) }

  # GUARDRAIL: PRIVILEGED CONTENT NEVER LEAVES BY DEFAULT.
  #
  # Attorney-client material is excluded from every outbound draft's context
  # unless a caller asks for it BY NAME. The mechanism lives here, on the model,
  # rather than inside the pipeline that consumes it — a rule enforced at the
  # source cannot be forgotten by the next consumer, and there will be more than
  # one consumer.
  #
  # `including_privileged: true` is the explicit opt-in, and it is deliberately
  # noisy to write.
  scope :for_context, ->(including_privileged: false) {
    including_privileged ? all : where(privileged: false)
  }

  def ask? = kind == "ask"
  def general? = kind == "general"

  # Whether this row may be handed to something that drafts outbound text.
  def contextable?(including_privileged: false)
    including_privileged || !privileged?
  end

  private

  def normalize
    self.kind = kind.to_s.strip.downcase.presence
    self.channel = channel.to_s.strip.downcase.presence
    self.direction = direction.presence && direction.to_s.strip.downcase
    self.entity = entity.presence && entity.to_s.strip
    self.thread_key = thread_key.presence && thread_key.to_s.strip
    self.external_id = external_id.presence && external_id.to_s.strip
    self.participants = [] if participants.nil?
    self.tags = [] if tags.nil?
    self.key_points = [] if key_points.nil?
    self.access = {} if access.nil?
    # An ask with no state is open. Left to a caller, this is the field that
    # ends up nil on half the rows and breaks the board query.
    self.status = "open" if ask? && status.blank?
  end

  def key_points_are_terse
    # jsonb stores a scalar or an object as happily as an array, so returning
    # early on a non-Array would let the cap be skipped by changing the TYPE —
    # 10,000 characters of `processing` prose landing here as a bare String.
    # Refuse it the way `participants_are_records` does, rather than pass it.
    unless key_points.is_a?(Array)
      errors.add(:key_points, "must be an array of short strings, got #{key_points.class}. " \
                              "Long-form reasoning belongs in `processing` — that is what it is for.")
      return
    end

    key_points.each_with_index do |point, index|
      unless point.is_a?(String)
        errors.add(:key_points, "entry #{index + 1} must be a string, got #{point.class}")
        next
      end

      if point.strip.empty?
        errors.add(:key_points, "entry #{index + 1} is blank")
      elsif point.length > KEY_POINT_MAX
        errors.add(:key_points,
                   "entry #{index + 1} is #{point.length} characters; the cap is #{KEY_POINT_MAX}. " \
                   "Long-form reasoning belongs in `processing` — that is what it is for.")
      end
    end
  end

  def participants_are_records
    return if participants.blank?

    unless participants.is_a?(Array)
      errors.add(:participants, "must be an array of {name, email, role, side} records")
      return
    end

    return if participants.all? { |participant| participant.is_a?(Hash) }

    errors.add(:participants, "every entry must be a {name, email, role, side} record")
  end

  # Same three levels as the knowledge layer, read from the engine's own
  # constant so the two cannot drift apart.
  def access_levels_are_known
    return if access.blank?

    unless access.is_a?(Hash)
      errors.add(:access, "must map an agent to a level")
      return
    end

    levels = Studio::KnowledgeDoc::ACCESS_LEVELS
    access.each do |agent, level|
      errors.add(:access, "#{agent} has unknown level #{level.inspect} (expected #{levels.join('/')})") unless levels.include?(level.to_s)
    end
  end

  def general_rows_carry_no_ask_fields
    return unless general?

    populated = ASK_ONLY_FIELDS.select { |field| self[field].present? }
    populated << :key_points if key_points.present?
    return if populated.empty?

    errors.add(:base, "a general row cannot carry ask fields (#{populated.join(', ')}) — " \
                      "it is either an ask, or those belong nowhere")
  end
end
