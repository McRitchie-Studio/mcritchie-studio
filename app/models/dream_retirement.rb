# frozen_string_literal: true

# Alex McRitchie's one-click retirement of an approved dream, from /dreams
# (docs/agents/modules/dream.md, Act 4). It is the "out" half of a swap, or a
# retirement on its own.
#
# Like DreamApproval, it cannot change the tracked files by itself. It waits here
# until a batch task runs `bin/dream apply-approvals`, which reads
# GET /api/v1/dream_retirements and DELETES the file (dream.md's "Dropped: delete
# the file" rule; a retired dream keeps no file and no `retired` status). Once the
# deployed bank no longer holds the dream, `reconcile!` stamps applied_at.
#
# A row's `ruling` is "retire" (an approved dream leaves its layer) or "drop" (a
# proposed dream is discarded); apply-approvals deletes the file either way.
#
# Only Alex McRitchie retires or drops: his click, behind the same DreamApproval.approver?
# check as an approval (via "click"), or his word in chat, recorded with the quote
# and the session through POST /api/v1/dream_rulings (DreamRuling, via "chat").
class DreamRetirement < ApplicationRecord
  class NotRetirable < StandardError; end

  belongs_to :retired_by, class_name: "User", foreign_key: :retired_by_slug, primary_key: :slug,
                          optional: true, inverse_of: false
  belongs_to :dream_swap, optional: true

  validates :dream_slug, :dream_home, :retired_at, presence: true
  validates :dream_slug, uniqueness: { scope: :dream_home }
  validates :via, inclusion: { in: %w[click chat] }
  validates :ruling, inclusion: { in: %w[retire drop] }
  validates :clearance, :session_id, presence: true, if: :chat?

  scope :pending, -> { where(applied_at: nil) }

  def key = "#{dream_home}/#{dream_slug}"

  def chat? = via == "chat"
  def drop? = ruling == "drop"

  # Raises NotRetirable, with the reason, unless `user` may retire `dream`.
  def self.check!(dream, user)
    raise NotRetirable, "only Alex McRitchie retires dreams" unless DreamApproval.approver?(user)
    raise NotRetirable, "no such dream" if dream.nil?
    raise NotRetirable, "`#{dream.slug}` is #{dream.status}, not approved" unless dream.approved?
  end

  # Records `user`'s retirement of `dream`. Idempotent: a second click returns the
  # first row, and a double-click that loses at the unique index or the uniqueness
  # validation returns the winner's row, as DreamApproval.record! does.
  def self.record!(dream, user, swap: nil)
    check!(dream, user)
    create_with(retired_by_slug: user.slug, retired_at: Time.current, dream_swap: swap)
      .find_or_create_by!(dream_home: dream.home, dream_slug: dream.slug)
  rescue ActiveRecord::RecordNotUnique
    find_by!(dream_home: dream.home, dream_slug: dream.slug)
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record.errors.of_kind?(:dream_slug, :taken)

    find_by!(dream_home: dream.home, dream_slug: dream.slug)
  end

  # Stamps applied_at on every pending row whose dream the deployed bank no longer
  # holds. Returns the number stamped. An empty bank is an unread bank (DreamBank.all
  # answers [] on a read failure), so it stamps nothing.
  def self.reconcile!(dreams, now: Time.current)
    present = Array(dreams).to_set { |dream| DreamApproval.key_for(dream) }
    return 0 if present.empty?

    ids = pending.reject { |row| present.include?(row.key) }.map(&:id)
    ids.empty? ? 0 : where(id: ids).update_all(applied_at: now, updated_at: now)
  end

  # The pending retirements, after reconciling, as { key => row }.
  def self.pending_by_key(dreams)
    reconcile!(dreams)
    pending.order(:retired_at).index_by(&:key)
  end

  # The read GET /api/v1/dream_retirements serves.
  def as_pending_json(dream)
    { dream_slug: dream_slug, dream_home: dream_home, path: "#{dream_home}/#{dream_slug}.md",
      retired_by: retired_by_slug, retired_at: retired_at&.iso8601,
      ruling: ruling, via: via, clearance: clearance, session_id: session_id,
      file_status: dream&.status.presence || "missing" }
  end
end
