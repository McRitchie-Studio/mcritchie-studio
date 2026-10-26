# frozen_string_literal: true

require Rails.root.join("bin/lib/dream_layers").to_s

# A session's one swap proposal at wrap (docs/agents/modules/dream.md, Act 4),
# posted by `bin/dream swap` through POST /api/v1/dream_swaps. One per session,
# in one of three kinds:
#
#   none  "no swap": both sides blank, with the reason. A valid answer.
#   add   one new dream in, when its layer has room.
#   swap  one in and one out, when its layer is full. The out must be one of the
#         layer's eligible candidates (DreamLoop: approved, past grace, not
#         already retiring); the session picks among them, the data ranks them.
#
# The IN is a `proposed` dream file the session wrote in its desk; it reaches the
# deployed bank only when that desk's PR ships, so the server records its key and
# layer as the session gives them.
#
# Alex McRitchie approves on /dreams with one click (approve!): the in through DreamApproval
# (the phase-1 approve) and the out through DreamRetirement, in one transaction.
# Agents propose; they never approve.
class DreamSwap < ApplicationRecord
  REASON_LIMIT = 160
  TOKEN = /\A[a-z0-9][a-z0-9-]*\z/
  HOME = %r{\A(?:[a-z0-9][a-z0-9-]*|sops/[a-z0-9][a-z0-9-]*)\z}

  class NotProposable < StandardError; end
  class NotApprovable < StandardError; end

  belongs_to :approved_by, class_name: "User", foreign_key: :approved_by_slug, primary_key: :slug,
                           optional: true, inverse_of: false
  has_many :dream_retirements, dependent: :nullify
  belongs_to :task, foreign_key: :task_slug, primary_key: :slug, optional: true, inverse_of: :dream_swaps
  include ClearsUnknownSlug
  clears_unknown_slug :task_slug, "Task"

  validates :session_id, presence: true, uniqueness: true
  validates :reason, presence: true, length: { maximum: REASON_LIMIT }
  validate :sides_are_sound

  scope :open, -> { where(approved_at: nil).where.not(in_slug: nil) }
  scope :newest, -> { order(created_at: :desc, id: :desc) }

  def kind
    return "none" if in_slug.blank?

    out_slug.present? ? "swap" : "add"
  end

  def in_key = in_slug.present? ? "#{in_home}/#{in_slug}" : nil
  def out_key = out_slug.present? ? "#{out_home}/#{out_slug}" : nil

  # Records the session's proposal against `dreams` (the deployed bank). Raises
  # NotProposable with the reason when the session already answered, or when the
  # proposal does not fit its layer.
  def self.propose!(session_id:, reason:, dreams:, in_key: nil, layer: nil, out_key: nil)
    raise NotProposable, "a swap needs the session id" if session_id.blank?
    raise NotProposable, "this session already answered the swap question" if exists?(session_id: session_id.to_s)

    in_home, in_slug = split_key(in_key)
    out_home, out_slug = split_key(out_key)
    fit!(layer.to_s, out_key, dreams) if in_slug

    origin = AgentAction.where(session_id: session_id.to_s).where.not(task_slug: nil)
                        .order(occurred_at: :desc, id: :desc).pick(:task_slug, :mascot)
    create!(session_id: session_id.to_s, reason: reason.to_s.squish.first(REASON_LIMIT),
            layer: in_slug ? layer.to_s : nil, in_home: in_home, in_slug: in_slug,
            out_home: out_home, out_slug: out_slug, task_slug: origin&.first, mascot: origin&.last)
  rescue ActiveRecord::RecordInvalid => e
    raise NotProposable, e.record.errors.full_messages.to_sentence
  rescue ActiveRecord::RecordNotUnique
    raise NotProposable, "this session already answered the swap question"
  end

  # "<home>/<slug>" -> [home, slug]; a step home keeps its "sops/" prefix.
  def self.split_key(key)
    return [ nil, nil ] if key.blank?

    home, _, slug = key.to_s.rpartition("/")
    [ home.presence, slug.presence ]
  end

  # A full layer needs an eligible out; a layer with room takes an add only.
  def self.fit!(layer, out_key, dreams)
    raise NotProposable, "`#{layer}` is not a layer (platform, soul/<slug>, step/<sop>/<step>)" unless DreamLayers.valid?(layer)

    report = DreamLoop.new(dreams).report(layer)
    if report.full?
      if out_key.blank?
        raise NotProposable, "#{report.label} is full (#{report.held} of #{report.budget}); name an out " \
                             "(bin/dream swap-candidates --layer #{layer})"
      end
      candidate = report.candidates.find { |entry| entry.key == out_key.to_s }
      raise NotProposable, "`#{out_key}` is not an approved dream in #{report.label}" unless candidate
      raise NotProposable, "`#{out_key}` is in its #{DreamLoop::GRACE_SESSIONS}-session grace" if candidate.in_grace
      raise NotProposable, "`#{out_key}` is already retiring" if candidate.retiring
    elsif out_key.present?
      raise NotProposable, "#{report.label} has room (#{report.room} of #{report.budget}); propose an add, no out"
    end
  end

  # Raises NotApprovable, with the reason, unless `user` may approve this swap
  # against `dreams` (the deployed bank). Returns [incoming, outgoing].
  def check!(user, dreams)
    raise NotApprovable, "only Alex McRitchie approves swaps" unless DreamApproval.approver?(user)
    raise NotApprovable, "a no-swap answer has nothing to approve" if kind == "none"
    raise NotApprovable, "already approved" if approved_at

    by_key = Array(dreams).index_by { |dream| DreamApproval.key_for(dream) }
    incoming = by_key[in_key]
    raise NotApprovable, "`#{in_key}` has not shipped yet; approve once its file is deployed" if incoming.nil?
    unless incoming.approved? || incoming.status == DreamApproval::PROPOSED
      raise NotApprovable, "`#{in_key}` is #{incoming.status}, not proposed"
    end

    outgoing = out_key && by_key[out_key]
    raise NotApprovable, "`#{out_key}` is not in the bank" if out_key && outgoing.nil?
    raise NotApprovable, "`#{out_key}` is #{outgoing.status}, not approved" if outgoing && !outgoing.approved?

    [ incoming, outgoing ]
  end

  # Alex McRitchie's one click: approves the in and retires the out, in one transaction.
  # Raises NotApprovable with the reason.
  def approve!(user, dreams)
    incoming, outgoing = check!(user, dreams)
    transaction do
      DreamApproval.record!(incoming, user) unless incoming.approved?
      DreamRetirement.record!(outgoing, user, swap: self) if outgoing
      update!(approved_at: Time.current, approved_by_slug: user.slug)
    end
    self
  end

  def as_json_row
    { session_id: session_id, kind: kind, layer: layer, in: in_key, out: out_key, reason: reason,
      task_slug: task_slug, mascot: mascot, proposed_at: created_at&.iso8601, approved_at: approved_at&.iso8601 }
  end

  private

  def sides_are_sound
    if in_slug.blank?
      errors.add(:base, "an out needs an in; retire a dream on its own from /dreams") if out_slug.present?
      return
    end
    errors.add(:base, "the in is not a bank key") unless HOME.match?(in_home.to_s) && TOKEN.match?(in_slug)
    errors.add(:base, "the out is not a bank key") if out_slug.present? && !(HOME.match?(out_home.to_s) && TOKEN.match?(out_slug))
    errors.add(:base, "the in and the out are the same dream") if in_key == out_key
    errors.add(:layer, "is not a layer") unless DreamLayers.valid?(layer)
  end
end
