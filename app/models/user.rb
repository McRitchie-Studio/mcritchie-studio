class User < ApplicationRecord
  include Sluggable

  # Passwordless app: email auth is magic-link only, plus Google + Solana wallet.
  # has_secure_password stays as a DORMANT fallback (password_digest column) but
  # `validations: false` is required so wallet/Google/magic-link users — who have
  # no password — can be created.
  has_secure_password validations: false
  has_one_attached :avatar

  # email + solana_address are both nullable (a wallet-only user has no email; an
  # email/Google user has no wallet) and unique when present.
  validates :email, uniqueness: true, allow_nil: true
  validates :solana_address, uniqueness: true, allow_nil: true
  validate :has_authentication_method

  before_create :ensure_session_token
  before_save :set_name_parts, if: -> { name_changed? }

  # --- Lookups / find-or-create ---------------------------------------------

  def self.from_solana_wallet(address)
    find_by(solana_address: address)
  end

  # OPSEC-005: `email_verified` comes from GoogleOauthValidator's tokeninfo
  # re-check (the engine OmniauthCallbacksController passes it). We only link a
  # Google identity onto an EXISTING email account when Google has confirmed the
  # email — otherwise an attacker who controls an unverified Google address for
  # someone else's email could hijack the account. Returns a User, or the symbol
  # :email_not_verified which the controller surfaces as a soft failure.
  def self.from_omniauth(auth, email_verified: false)
    user = find_by(provider: auth.provider, uid: auth.uid)
    return user if user

    email = auth.info.email
    if email.present? && (existing = find_by(email: email))
      return :email_not_verified unless email_verified
      existing.update!(provider: auth.provider, uid: auth.uid,
                       email_verified_at: existing.email_verified_at || Time.current)
      return existing
    end

    create!(
      email: email,
      name: auth.info.name,
      provider: auth.provider,
      uid: auth.uid,
      email_verified_at: email_verified ? Time.current : nil
    )
  rescue ActiveRecord::RecordNotUnique
    # Race: a concurrent callback created the user between find_by and create!.
    find_by(email: auth.info.email) || find_by(provider: auth.provider, uid: auth.uid)
  end

  # --- Predicates ------------------------------------------------------------

  def admin?
    role == "admin"
  end

  def google_connected?
    provider.present? && uid.present?
  end

  # In the hub the wallet is identity-only (one address); a connected wallet is
  # treated as a self-custody/Phantom wallet for SessionContext purposes.
  def solana_connected?
    solana_address.present?
  end
  alias_method :phantom_wallet?, :solana_connected?

  def has_email?
    email.present?
  end

  # --- Session token (OPSEC-045) --------------------------------------------

  def regenerate_session_token!
    update!(session_token: SecureRandom.hex(32))
  end

  # --- Display ---------------------------------------------------------------

  def display_name
    name.presence || email&.split("@")&.first&.capitalize || truncated_solana || "anon"
  end

  def truncated_solana
    return nil if solana_address.blank?
    "#{solana_address[0, 4]}…#{solana_address[-4, 4]}"
  end

  def avatar_initials
    (name.presence || email&.split("@")&.first || solana_address || "?").first.upcase
  end

  AVATAR_COLORS = %w[#EF4444 #F97316 #EAB308 #22C55E #06B6D4 #3B82F6 #8B5CF6 #EC4899].freeze

  def avatar_color
    key = name.presence || email || solana_address || id.to_s
    AVATAR_COLORS[Digest::MD5.hexdigest(key).hex % AVATAR_COLORS.size]
  end

  private

  def has_authentication_method
    return if email.present? || solana_address.present? || google_connected?
    errors.add(:base, "must have an email, wallet, or linked Google account")
  end

  def ensure_session_token
    self.session_token ||= SecureRandom.hex(32)
  end

  def set_name_parts
    parts = name.to_s.strip.split(" ")
    self.first_name = parts.first
    self.last_name = parts.last if parts.size > 1
  end

  # Unique URL slug. Keyed on a unique identifier (email or wallet address) so
  # wallet-only users — who have no email — still get a collision-free slug.
  def name_slug
    identifier = email.presence || solana_address.presence || "user"
    prefix = name.presence || email&.split("@")&.first || truncated_solana || "user"
    "#{prefix}-#{identifier}".downcase.gsub(/\s+/, "-")
  end
end
