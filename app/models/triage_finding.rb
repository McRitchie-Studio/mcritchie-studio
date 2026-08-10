# frozen_string_literal: true

# A triage finding — an agent-discovered follow-up that has NOT been promoted to
# a task. The inbox is the default destination for retro follow-ups, review
# side-findings, and audit discoveries; it decouples "worth remembering" from
# "worth a worktree + review + release slot". Promotion is the OPERATOR's lane
# (admin-gated web UI, like approval grants) — the bearer API can file and list
# findings but never promote them.
class TriageFinding < ApplicationRecord
  STATUSES = %w[open promoted dismissed].freeze

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :slug, presence: true, uniqueness: true
  attr_readonly :slug

  before_validation :generate_slug, on: :create

  scope :recent, -> { order(created_at: :desc) }
  scope :open_findings, -> { where(status: "open").recent }
  scope :resolved, -> { where.not(status: "open").order(resolved_at: :desc) }

  # Stamp the promotion linkage. The Task is created by the caller (the admin
  # controller) so its creation rides the same validations and identity hooks as
  # every other task; this only records where the finding went.
  def promote!(task)
    update!(status: "promoted", promoted_task_slug: task.slug, resolved_at: Time.current)
  end

  def dismiss!
    update!(status: "dismissed", resolved_at: Time.current)
  end

  private

  def generate_slug
    self.slug = "finding-#{SecureRandom.hex(6)}" if slug.blank?
  end
end
