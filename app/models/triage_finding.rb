# frozen_string_literal: true

# A triage finding — an agent-discovered follow-up that has NOT been promoted to
# a task. The inbox is the default destination for retro follow-ups, review
# side-findings, and audit discoveries; it decouples "worth remembering" from
# "worth a worktree + review + release slot". Promotion is the OPERATOR's lane
# (admin-gated web UI, like approval grants) — the bearer API can file and list
# findings but never promote them.
class TriageFinding < ApplicationRecord
  STATUSES = %w[open promoted dismissed].freeze

  # PRIOR ART — did this surface already exist, under what controls, before the
  # change in hand? Three states, and the THIRD one is the whole point:
  #
  #   unknown — nobody looked. The DEFAULT, and an ANSWER, not an absence.
  #   none    — somebody looked; the surface is new here.
  #   found   — somebody looked; `prior_art_note` says what was already there.
  #
  # `unknown` exists because a blank reads as `none`. finding-6a5fdcd157b3
  # claimed turf-monster was "the first consumer where the iframe actually
  # renders" — false; TM's DELETED view had carried the identical unsandboxed
  # iframe, same URL, same 8 previews, same CSP. Net exposure change: zero. An
  # advisory that omits prior art does not merely lack a detail; it invites the
  # reader to supply "none", and the reader will.
  PRIOR_ART_STATES = %w[unknown none found].freeze

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :prior_art, inclusion: { in: PRIOR_ART_STATES }
  validates :slug, presence: true, uniqueness: true
  validate :found_prior_art_carries_its_evidence
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

  def prior_art_investigated?
    prior_art != "unknown"
  end

  # One human line for every render surface (CLI confirmation, inbox card,
  # promoted agent_context) so the three states can never be paraphrased into
  # two by whichever view happens to be showing them.
  def prior_art_summary
    case prior_art
    when "found" then "checked — #{prior_art_note}"
    when "none" then "checked — none found; this surface is new here"
    else "NOT INVESTIGATED — nobody checked whether this surface already existed"
    end
  end

  # What a promoted task inherits. The uninvestigated case carries an explicit
  # INSTRUCTION, not just a label: the failure being prevented is a downstream
  # agent inheriting a framing ("this change introduces X") that the finding
  # never actually established.
  def prior_art_context
    return prior_art_summary if prior_art_investigated?

    "#{prior_art_summary}. Establish what was there BEFORE assuming this change " \
      "introduced it — read the code it replaced, deleted files included."
  end

  private

  # `found` with no note is the blank trap wearing a badge: it claims the check
  # happened while recording nothing a reader can verify or disagree with.
  def found_prior_art_carries_its_evidence
    return unless prior_art == "found" && prior_art_note.blank?

    errors.add(:prior_art_note, "is required when prior art was found")
  end

  def generate_slug
    self.slug = "finding-#{SecureRandom.hex(6)}" if slug.blank?
  end
end
