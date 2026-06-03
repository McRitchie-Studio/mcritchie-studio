# A registered System-Program durable nonce account the signing console can
# anchor transactions on. A nonce-anchored tx never expires (until consumed), so
# a half-signed multisig tx can wait for other signers across browsers/sessions.
#
# The `authority` is who signs nonceAdvance on every tx anchored here — for the
# keyless console it's one of the Phantom signers (so no server key + no extra
# signature, since that signer is already on the tx). One row per cluster to
# start; the table is already a pool (add rows + round-robin for concurrency).
#
# Created out-of-band (rake signing:create_nonce_account or `solana
# create-nonce-account`); this record is just the registry pointer + authority.
class DurableNonce < ApplicationRecord
  include Sluggable

  STATUSES = %w[active retired].freeze

  validates :pubkey, :authority, :cluster, presence: true
  validates :pubkey, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }
  scope :for_cluster, ->(c) { where(cluster: c.to_s) }

  # The active nonce for a cluster (first of the pool, for now).
  def self.active_for(cluster)
    active.for_cluster(cluster).order(:created_at).first
  end

  def label_or_pubkey
    label.presence || "#{pubkey[0, 4]}…#{pubkey[-4, 4]}"
  end

  private

  def name_slug
    slug.presence || "nonce-#{SecureRandom.hex(4)}"
  end
end
