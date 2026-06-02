# A proposed on-chain instruction awaiting one or more Phantom signatures, plus
# its lifecycle. This is the persistent, Squads-style QUEUE record behind the v2
# admin signing console — it generalizes turf-monster's PendingTransaction
# (treasury cosign) to any program/instruction and to N independent signers.
#
# THE SERVER HOLDS NO KEYS. A SigningRequest stores only the unsigned message
# and the PUBLIC signatures collected from each signer's own browser/Phantom.
# When enough signatures are gathered it is assembled + broadcast (broadcasting a
# fully-signed public tx needs no key).
#
# Two signer topologies (`coordination`):
#   - single : one human wallet (e.g. turf-vault `initialize` = the INIT_AUTHORITY).
#              Fresh blockhash, threshold 1, no nonce coordination.
#   - multi  : N wallets signing in separate sessions, coordinated over a DURABLE
#              NONCE so a half-signed tx doesn't expire between signers.
#
# The unsigned message + Borsh encoding are produced by Signing::SigningRequest
# (the builder PORO) from the pinned IDL; the byte-match gate guards the encoder.
class SigningRequest < ApplicationRecord
  include Sluggable

  COORDINATIONS = %w[single multi].freeze
  STATUSES      = %w[awaiting_signatures fully_signed broadcast failed].freeze

  validates :program, :program_id, :cluster, :instruction_name, presence: true
  validates :coordination, inclusion: { in: COORDINATIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :threshold, numericality: { greater_than: 0 }

  scope :open, -> { where(status: %w[awaiting_signatures fully_signed]) }
  scope :recent, -> { order(created_at: :desc) }

  # --- signer progress --------------------------------------------------------

  def signers_signed
    collected_signatures.keys
  end

  def remaining_signers
    expected_signers - signers_signed
  end

  def signed_by?(pubkey)
    collected_signatures.key?(pubkey.to_s)
  end

  def signatures_needed
    [threshold - signers_signed.length, 0].max
  end

  def threshold_met?
    signers_signed.length >= threshold
  end

  # Record one signer's PUBLIC signature. Idempotent per signer; only accepts a
  # pubkey we actually expect. Flips status to fully_signed once threshold is met.
  def record_signature!(pubkey:, signature_b64:)
    pubkey = pubkey.to_s
    unless expected_signers.include?(pubkey)
      raise ArgumentError, "#{pubkey} is not an expected signer for this request"
    end

    self.collected_signatures = collected_signatures.merge(pubkey => signature_b64)
    self.status = "fully_signed" if threshold_met? && status == "awaiting_signatures"
    save!
  end

  def mark_broadcast!(tx_signature)
    update!(status: "broadcast", tx_signature: tx_signature, last_error: nil)
  end

  def mark_failed!(message)
    update!(status: "failed", last_error: message.to_s.first(2000))
  end

  # --- predicates / display ---------------------------------------------------

  def single?
    coordination == "single"
  end

  def multi?
    coordination == "multi"
  end

  def broadcast?
    status == "broadcast"
  end

  def status_label
    status.tr("_", " ")
  end

  private

  # Stable random slug (Sluggable rewrites slug from name_slug on every save, so
  # this must be idempotent — return the existing slug once assigned).
  def name_slug
    slug.presence || "sr-#{SecureRandom.hex(6)}"
  end
end
