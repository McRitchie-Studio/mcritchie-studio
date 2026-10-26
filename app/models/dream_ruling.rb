# frozen_string_literal: true

require Rails.root.join("bin/lib/dream_clearance").to_s

# Alex McRitchie's ruling on a dream, given in chat and recorded by an agent with his quoted
# words (docs/agents/modules/dream.md, Act 3, "In chat"), through
# POST /api/v1/dream_rulings and `bin/dream approve|drop|retire --clearance`.
#
#   approve  a proposed dream → a DreamApproval
#   drop     a proposed dream → a DreamRetirement with ruling "drop"
#   retire   an approved dream → a DreamRetirement with ruling "retire"
#
# Each row is stamped via "chat", with the verbatim clearance and the recording
# session, and names Alex McRitchie as the approver. That is the house precedent for
# production (`bin/release ship --mode cleared --clearance`): his clearance in
# chat is the grant, and the words are the audit trail. It is not a signature,
# and it is not an agent's own judgment: an agent records only what Alex McRitchie said in
# that session. A row Alex McRitchie already made with a click stands; a second ruling on
# the same dream returns it.
#
# `bin/dream apply-approvals` writes all three into the files as it does a click:
# an approval flips the file to approved, a drop or a retirement deletes it.
class DreamRuling
  RULINGS = %w[approve drop retire].freeze

  class Refused < StandardError; end

  # Records the ruling. Returns [row, created?]; raises Refused with the reason.
  def self.record!(ruling:, dream:, clearance:, session_id:)
    new(ruling.to_s, dream, clearance.to_s.strip, session_id.to_s.strip).record!
  end

  # Alex McRitchie's User row slug, the approver every chat ruling names; nil when the hub
  # holds no such user (the column then stays blank and `via` still says chat).
  def self.approver_slug
    User.where("lower(email) IN (?)", DreamApproval::APPROVER_EMAILS).pick(:slug)
  end

  def initialize(ruling, dream, clearance, session_id)
    @ruling = ruling
    @dream = dream
    @clearance = clearance
    @session_id = session_id
  end

  def record!
    check!
    existing = existing_row
    return [ existing, false ] if existing

    [ create_row!, true ]
  rescue ActiveRecord::RecordNotUnique
    [ existing_row || raise(Refused, "a ruling on `#{@dream.slug}` raced this one; read /dreams"), false ]
  end

  private

  def key = { dream_home: @dream.home, dream_slug: @dream.slug }

  def check!
    raise Refused, "`#{@ruling}` is not a ruling (#{RULINGS.join(", ")})" unless RULINGS.include?(@ruling)
    raise Refused, "no such dream in the deployed bank; a dream still only in a desk is ruled in its file" if @dream.nil?
    raise Refused, "a chat ruling needs the session that heard it" if @session_id.empty?

    problem = DreamClearance.problem(@clearance, slug: @dream.slug)
    raise Refused, problem if problem

    wanted = @ruling == "retire" ? "approved" : DreamApproval::PROPOSED
    raise Refused, "`#{@dream.slug}` is #{@dream.status.presence || "without a status"}, not #{wanted}" unless @dream.status == wanted

    conflict!
  end

  # An approval and a drop of the same proposed dream cannot both stand.
  def conflict!
    case @ruling
    when "approve"
      dropped = DreamRetirement.pending.find_by(key)
      raise Refused, "`#{@dream.slug}` already has a pending #{dropped.ruling}" if dropped
    when "drop"
      raise Refused, "`#{@dream.slug}` already has a pending approval" if DreamApproval.pending.exists?(key)
    end
  end

  def existing_row
    @ruling == "approve" ? DreamApproval.find_by(key) : DreamRetirement.find_by(key)
  end

  def stamp = { via: "chat", clearance: @clearance, session_id: @session_id }

  def create_row!
    by = self.class.approver_slug
    if @ruling == "approve"
      DreamApproval.create!(key.merge(stamp).merge(approved_by_slug: by, approved_at: Time.current))
    else
      DreamRetirement.create!(key.merge(stamp).merge(retired_by_slug: by, retired_at: Time.current, ruling: @ruling))
    end
  end
end
