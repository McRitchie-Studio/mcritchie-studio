# The TikTok account the hub drafts to: what /admin/tiktok/callback stores when
# an admin finishes the sign-in, so no token is ever copied by hand or shown.
#
# One row per TikTok account (open_id, unique). Signing the same account in
# again updates its row; the connection in use is .current, the one connected
# most recently. The refresh token is encrypted at rest (Active Record
# Encryption, non-deterministic, as Fact#value is) and masked in every inspect.
#
# TikTok may answer a token refresh with a new refresh token. #rotate! keeps
# the stored one current (Tiktok::OAuthClient calls it); without that the row
# would go stale the first time TikTok rotated.
class TiktokConnection < ApplicationRecord
  encrypts :refresh_token
  self.filter_attributes += %i[refresh_token]

  validates :open_id, presence: true, uniqueness: true
  validates :refresh_token, :connected_at, presence: true

  class << self
    # The connection the hub uses: the most recently connected account.
    def current = order(connected_at: :desc, id: :desc).first

    # Stores what TikTok answered to a sign-in's code exchange (`grant`: the
    # token endpoint's JSON). The account's row is updated when it exists.
    # Raises ActiveRecord::RecordInvalid when the answer lacks the open id or
    # the refresh token; the message names the field and never a value.
    def store!(grant, by:, now: Time.current)
      attempts = 0
      begin
        connection = find_or_initialize_by(open_id: grant["open_id"].to_s)
        connection.assign_attributes(
          refresh_token: grant["refresh_token"].to_s,
          scope: grant["scope"].to_s.presence,
          connected_by: by,
          connected_at: now,
          refreshed_at: nil,
          refresh_expires_at: expiry(grant, now)
        )
        connection.save!
        connection
      rescue ActiveRecord::RecordNotUnique # two sign-ins for one new account, at once
        retry if (attempts += 1) < 2
        raise
      end
    end

    # When the refresh token in `grant` dies, from TikTok's refresh_expires_in
    # (seconds). nil when TikTok named no positive number.
    def expiry(grant, now)
      seconds = Integer(grant["refresh_expires_in"].to_s, exception: false)
      now + seconds if seconds&.positive?
    end
  end

  # Saves the refresh token TikTok returned with a token refresh, when it
  # differs from the stored one. Returns whether it wrote.
  def rotate!(grant, now: Time.current)
    returned = grant["refresh_token"].to_s
    return false if returned.empty? || returned == refresh_token

    update!(refresh_token: returned, refreshed_at: now, refresh_expires_at: self.class.expiry(grant, now))
    true
  end

  # The granted scope as names (TikTok writes one comma-separated string).
  def scopes = Tiktok::OAuthClient.split_scopes(scope)

  # What a page calls this account: its display name, or its open id.
  def account = display_name.presence || open_id
end
