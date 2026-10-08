# One attempt to put a clip's primary version into the operator's TikTok
# drafts (recast pipeline, piece 19). Every attempt is its own row, kept, so a
# retry never hides what the last try did.
#
#   queued      recorded; the job has not started the upload
#   uploading   the job opened TikTok's inbox upload and is sending the bytes
#   processing  every byte is with TikTok (it gave a publish_id); TikTok is
#               still processing, so the draft may not be on the phone yet
#   unknown     every byte is with TikTok, but its status could not be read (or
#               our own record of the finished upload broke). The draft may be
#               on the phone: the operator looks there, and "Check TikTok"
#               reads the status again. Never `failed`: a failed attempt
#               invites another, and that one would be a second draft
#   delivered   TikTok's status is SEND_TO_USER_INBOX: the draft is in the
#               operator's TikTok inbox, private until he posts it
#   failed      TikTok refused or the upload broke; `error` says how
#
# `tiktok_status` is TikTok's own word from its publish status endpoint
# (PROCESSING_UPLOAD, SEND_TO_USER_INBOX, PUBLISH_COMPLETE, FAILED), kept beside
# ours. The caption is written by code (Tiktok::ClipCaption) when the attempt is
# recorded. TikTok's inbox upload takes no caption, so the operator pastes it on
# the phone: the card and bin/tiktok-draft both show it with a Copy.
class TiktokDraft < ApplicationRecord
  STATES = %w[queued uploading processing unknown delivered failed].freeze
  # In flight: a clip with one of these (younger than Tiktok::DraftClip::STUCK_AFTER) takes no new attempt.
  PENDING = %w[queued uploading processing unknown].freeze
  # TikTok holds the bytes and has not said how it went: a status read can settle these.
  WITH_TIKTOK = %w[processing unknown].freeze

  belongs_to :clip, class_name: "AltVideoClip", foreign_key: :clip_slug, primary_key: :slug, inverse_of: :tiktok_drafts

  validates :state, inclusion: { in: STATES }
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :version_object_key, :caption, presence: true

  scope :pending, -> { where(state: PENDING) }

  def pending? = PENDING.include?(state)

  def delivered? = state == "delivered"

  def failed? = state == "failed"

  # Can "Check TikTok" (Tiktok::DraftClip#refresh) do anything for this attempt?
  def with_tiktok? = WITH_TIKTOK.include?(state)

  # "Version 2", the version this attempt sent.
  def version_name = "Version #{version_number}"

  # What the card and the bin print for the state, in the operator's words.
  def state_label
    case state
    when "queued" then "Queued"
    when "uploading" then "Uploading to TikTok"
    when "processing" then "TikTok is processing it"
    when "unknown" then "Uploaded, status unknown"
    when "delivered" then "In your TikTok drafts"
    else "Failed"
    end
  end

  # The attempt as the API and bin/tiktok-draft read it.
  def as_report
    { "id" => id, "clip_slug" => clip_slug, "version_number" => version_number, "state" => state,
      "state_label" => state_label, "tiktok_status" => tiktok_status, "publish_id" => publish_id,
      "caption" => caption, "facts" => facts, "error" => error, "fail_reason" => fail_reason,
      "byte_size" => byte_size, "chunk_count" => chunk_count, "requested_by" => requested_by,
      "created_at" => created_at&.utc&.iso8601, "uploaded_at" => uploaded_at&.utc&.iso8601,
      "polled_at" => polled_at&.utc&.iso8601, "finished_at" => finished_at&.utc&.iso8601 }
  end
end
