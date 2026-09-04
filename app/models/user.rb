class User < ApplicationRecord
  include Sluggable

  # Stable operator identities whose roles and wallet/email links should survive
  # fresh DBs, first-login races, QA resets, and new-app clones of this pattern.
  #
  # THE ADMIN LINE IS WHAT THIS LIST IS FOR. Three seats hold admin — the
  # operator, the shared team account, and the super-admin lane — and everyone
  # else is a viewer. Mason and the Turf Monster house account were admins until
  # 2026-09-04; demoting them is what makes admin-only pages, member-facing copy
  # and anything branching on a role have more than one answer available here.
  PARKED_IDENTITIES = [
    { email: "alex@mcritchie.studio",  name: "Alex McRitchie",  role: "admin",  wallet: "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr" },
    { email: "team@mcritchie.studio",  name: "Team McRitchie",  role: "admin",  wallet: "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd" },
    # THE SUPER-ADMIN LANE, wallet-less on purpose. admin@mcritchie.studio is the
    # top-of-stack Google credential the Steffon and Alex agents sign in with
    # (1Password `google.studio.admin`, vault `studio-agents-admin`). It is an
    # operator SEAT rather than a person, so it holds no funds and signs nothing
    # on-chain — giving it a wallet would put the highest-privilege login on the
    # same key as a spending account.
    { email: "admin@mcritchie.studio", name: "Admin McRitchie", role: "admin" },
    { email: "mason@mcritchie.studio", name: "Mason McRitchie", role: "viewer", wallet: "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR" },
    # Mack rather than an invented account: he is already the non-admin in
    # turf-monster and mcritchie-industries, so one person means the same thing
    # in all three apps instead of each growing its own stand-in. (The role
    # VALUES differ — this app has no "user" role; its default is "viewer" — so
    # only the meaning is shared.)
    #
    # He keeps his name. An earlier draft of this task wanted a NAMELESS member
    # so the email manager could preview what someone with no name on file
    # receives; stripping a real person's name to serve a preview is the wrong
    # trade, and that preview is now a sample recipient in the engine instead.
    { email: "mack@mcritchie.studio",  name: "Mack McRitchie",  role: "viewer" },
    # THE TURF HOUSE ACCOUNT, now on Turf's own domain. It moved off
    # turf@mcritchie.studio on 2026-09-04: that address was a forwarding GROUP
    # with zero members, and team@turfmonster.media is a real Google user
    # (1Password `google.turf.agents`). A viewer here — Turf Monster is an admin
    # in its OWN app, and nothing about running that app needs the hub's admin
    # surface. RETIRED_EMAILS is how the rows already sitting on the old address
    # follow it.
    { email: "team@turfmonster.media", name: "Turf Monster",    role: "viewer" }
  ].freeze

  # Addresses a parked identity has MOVED OFF, old => new.
  #
  # A role demotion reaches an existing row on its next save, because
  # `assign_parked_identity` re-reads the roster by email. An EMAIL change cannot:
  # the old row stops matching any parked identity at all, so it keeps whatever
  # role it was last saved with — and turf@mcritchie.studio was last saved as an
  # ADMIN whose Google group is being deleted. That leftover is the whole reason
  # this map exists: `db/seeds/01_users.rb` renames the old row before it creates
  # anything, so a local, test or QA database converges on a re-seed instead of
  # growing a second Turf account.
  #
  # Deployed rows are reached by a one-time data migration instead, and that
  # migration deliberately SPELLS THE PAIR OUT rather than reading this constant.
  # A migration is a historical record that must still run years from now against
  # whatever this class has become; a constant is a live fact that gets renamed
  # and deleted. Coupling the two makes a future rename break `db:migrate` on a
  # fresh clone.
  RETIRED_EMAILS = {
    "turf@mcritchie.studio" => "team@turfmonster.media"
  }.freeze

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
  before_validation :assign_parked_identity
  before_save :set_name_parts, if: -> { name_changed? }

  # --- Lookups / find-or-create ---------------------------------------------

  def self.from_solana_wallet(address)
    normalized_address = address.to_s.strip
    user = find_by(solana_address: normalized_address)
    if user
      user.claim_parked_identity!
      return user
    end

    identity = parked_identity_for(wallet: normalized_address)
    if identity && (existing = find_by(email: identity[:email]))
      existing.solana_address = normalized_address if existing.solana_address.blank?
      existing.claim_parked_identity!
      return existing if existing.solana_address == normalized_address
    end

    nil
  end

  def self.parked_identity_for(email: nil, wallet: nil)
    normalized_email = email.to_s.strip.downcase.presence
    normalized_wallet = wallet.to_s.strip.presence
    return nil if normalized_email.blank? && normalized_wallet.blank?

    PARKED_IDENTITIES.find do |identity|
      (normalized_email.present? && identity[:email].to_s.downcase == normalized_email) ||
        (normalized_wallet.present? && identity[:wallet].to_s == normalized_wallet)
    end
  end

  # OPSEC-005: `email_verified` comes from GoogleOauthValidator's tokeninfo
  # re-check (the engine OmniauthCallbacksController passes it). We only link a
  # Google identity onto an EXISTING email account when Google has confirmed the
  # email — otherwise an attacker who controls an unverified Google address for
  # someone else's email could hijack the account. Returns a User, or the symbol
  # :email_not_verified which the controller surfaces as a soft failure.
  def self.from_omniauth(auth, email_verified: false)
    user = find_by(provider: auth.provider, uid: auth.uid)
    if user
      user.claim_parked_identity!
      return user
    end

    email = auth.info.email
    if email.present? && (existing = find_by(email: email))
      return :email_not_verified unless email_verified
      existing.update!(provider: auth.provider, uid: auth.uid,
                       email_verified_at: existing.email_verified_at || Time.current)
      existing.claim_parked_identity!
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

  def claim_parked_identity!
    return false unless assign_parked_identity

    save! if persisted? && changed?
    true
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

  def assign_parked_identity
    identity = self.class.parked_identity_for(email: email, wallet: solana_address)
    return false unless identity

    changed_identity = false

    parked_role = identity[:role].presence
    if parked_role.present? && role != parked_role
      self.role = parked_role
      changed_identity = true
    end

    parked_name = identity[:name].presence
    if parked_name.present? && (name.blank? || name == "anon")
      self.name = parked_name
      changed_identity = true
    end

    parked_email = identity[:email].presence
    if parked_email.present? && email.blank? && self.class.where("LOWER(email) = ?", parked_email.downcase).where.not(id: id).none?
      self.email = parked_email
      changed_identity = true
    end

    parked_wallet = identity[:wallet].presence
    if parked_wallet.present? && solana_address.blank? && self.class.where(solana_address: parked_wallet).where.not(id: id).none?
      self.solana_address = parked_wallet
      changed_identity = true
    end

    changed_identity
  end

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
