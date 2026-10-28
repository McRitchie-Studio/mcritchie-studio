# A satellite app's own bearer credential to a hub API: today the agent chat
# (Api::V1::AgentChatsController; docs/agents/system/agent-message-loop.md,
# "Satellite chat"). It names an APP, never a user or a soul: what the app may
# reach is config/agent_routes.yml's `web: apps:` allow-list.
#
# THE SECRET IS NEVER STORED. issue! returns it once, with the row; the row keeps
# its SHA-256 digest. A secret is 256 random bits, so the digest is looked up by
# index and compared in constant time. Minting again for the same app and purpose
# revokes the live one (one credential per app per purpose), so a rotation is
# mint, file, set the app's config, done.
class AppCredential < ApplicationRecord
  PURPOSES = %w[agent-chat].freeze
  # The prefix every secret carries, so a leaked one is recognisable in a scan.
  PREFIX = { "agent-chat" => "hubchat_" }.freeze
  SLUG = /\A[a-z0-9][a-z0-9-]{0,62}\z/
  # last_used_at is written at most this often, so a polling app is not a write
  # per poll.
  TOUCH_EVERY = 5.minutes

  validates :app_slug, format: { with: SLUG }
  validates :purpose, inclusion: { in: PURPOSES }
  validates :token_digest, presence: true, uniqueness: true

  scope :live, -> { where(revoked_at: nil) }

  def self.digest(secret) = Digest::SHA256.hexdigest(secret.to_s)

  # [row, secret]: the secret is in no row and no log; hand it to the operator once.
  def self.issue!(app_slug:, purpose:, label: nil, issued_by: nil, now: Time.current)
    secret = "#{PREFIX.fetch(purpose.to_s)}#{SecureRandom.urlsafe_base64(32)}"
    row = transaction do
      live.where(app_slug: app_slug.to_s, purpose: purpose.to_s).find_each { |old| old.revoke!(by: issued_by || "rotation", now: now) }
      create!(app_slug: app_slug.to_s, purpose: purpose.to_s, token_digest: digest(secret), label: label.presence,
              issued_by: issued_by.presence)
    end
    [ row, secret ]
  end

  # The live credential `secret` names for `purpose`, or nil.
  def self.authenticate(secret, purpose:, now: Time.current)
    secret = secret.to_s
    return nil if secret.empty? || secret.length > 200

    wanted = digest(secret)
    row = live.find_by(purpose: purpose.to_s, token_digest: wanted)
    return nil unless row && ActiveSupport::SecurityUtils.secure_compare(row.token_digest, wanted)

    row.touch_used!(now)
    row
  end

  def revoke!(by: nil, now: Time.current)
    update!(revoked_at: now, revoked_by: by.presence)
  end

  def revoked? = revoked_at.present?

  def touch_used!(now = Time.current)
    return if last_used_at && last_used_at > now - TOUCH_EVERY

    update_column(:last_used_at, now)
  end
end
