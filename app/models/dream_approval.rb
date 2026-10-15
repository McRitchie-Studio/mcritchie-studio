# frozen_string_literal: true

# Alex's one-click approval of a proposed dream, recorded from /dreams
# (docs/agents/modules/dream.md, Act 3).
#
# The bank is tracked files that the session-start hook and bin/dream read offline,
# so an approval cannot flip a file by itself. It waits here until a batch task runs
# `bin/dream apply-approvals` (which reads GET /api/v1/dream_approvals), and the
# release carrying that batch ships. Once the deployed file reads
# `status: approved`, `reconcile!` stamps applied_at and the row stops being pending.
#
# Only Alex approves. A row is created by DreamsController#approve, behind the admin
# wall and the APPROVER_EMAILS check; no /api/v1 action creates one, so no agent
# token can.
class DreamApproval < ApplicationRecord
  # The human who signs dreams off. admin@ is an agent seat and team@ a shared
  # account, so being an admin is not enough.
  APPROVER_EMAILS = %w[alex@mcritchie.studio].freeze
  PROPOSED = "proposed"

  class NotApprovable < StandardError; end

  belongs_to :approved_by, class_name: "User", foreign_key: :approved_by_slug, primary_key: :slug,
                           optional: true, inverse_of: false

  validates :dream_slug, :dream_home, :approved_at, presence: true
  validates :dream_slug, uniqueness: { scope: :dream_home }

  scope :pending, -> { where(applied_at: nil) }

  def self.approver?(user)
    user.present? && user.admin? && APPROVER_EMAILS.include?(user.email.to_s.downcase)
  end

  # "<home>/<slug>", the key a dream and its approval share.
  def self.key_for(dream) = "#{dream.home}/#{dream.slug}"

  def key = "#{dream_home}/#{dream_slug}"

  # Records `user`'s approval of `dream` (a DreamBank::Dream). Raises NotApprovable
  # unless the user is the approver and the dream reads `proposed`. Idempotent: a
  # second click returns the first row.
  def self.record!(dream, user)
    check!(dream, user)
    create_with(approved_by_slug: user.slug, approved_at: Time.current)
      .find_or_create_by!(dream_home: dream.home, dream_slug: dream.slug)
  rescue ActiveRecord::RecordNotUnique
    find_by!(dream_home: dream.home, dream_slug: dream.slug)
  end

  # Raises NotApprovable, with the reason, unless `user` may approve `dream`.
  def self.check!(dream, user)
    raise NotApprovable, "only Alex approves dreams" unless approver?(user)
    raise NotApprovable, "no such dream" if dream.nil?
    raise NotApprovable, "`#{dream.slug}` is #{dream.status}, not proposed" unless dream.status == PROPOSED
  end

  # Stamps applied_at on every pending row whose dream now reads approved in
  # `dreams` (the deployed bank). Returns the number stamped.
  def self.reconcile!(dreams, now: Time.current)
    approved = Array(dreams).select(&:approved?).to_set { |dream| key_for(dream) }
    ids = pending.select { |row| approved.include?(row.key) }.map(&:id)
    ids.empty? ? 0 : where(id: ids).update_all(applied_at: now, updated_at: now)
  end

  # The pending approvals, after reconciling, as { key => row }.
  def self.pending_by_key(dreams)
    reconcile!(dreams)
    pending.order(:approved_at).index_by(&:key)
  end

  # The read GET /api/v1/dream_approvals serves. `file_status` is what the deployed
  # file reads now: `proposed`, or `missing` when the file is gone.
  def as_pending_json(dream)
    { dream_slug: dream_slug, dream_home: dream_home, path: "#{dream_home}/#{dream_slug}.md",
      approved_by: approved_by_slug, approved_at: approved_at&.iso8601,
      file_status: dream&.status.presence || "missing" }
  end
end
