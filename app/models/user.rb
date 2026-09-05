class User < ApplicationRecord
  include Sluggable

  # Stable operator identities whose roles and email links should survive fresh
  # DBs, first-login races, QA resets, and new-app clones of this pattern.
  #
  # EMAIL IS THE ONLY KEY. It used to be email OR wallet; the wallet half went
  # with users.solana_address on 2026-09-04 (/tasks/drop-hub-wallet-column), so
  # an identity that carries no `email:` is now unreachable — `parked_identity_for`
  # cannot find it and nothing will ever apply its role. ParkedIdentitiesTest
  # asserts every entry has one, so a future wallet-only row fails loudly here
  # instead of silently never being recognised.
  #
  # THE ADMIN LINE IS WHAT THIS LIST IS FOR. Three seats hold admin — the
  # operator, the shared team account, and the super-admin lane — and everyone
  # else is a viewer. Mason and the Turf Monster house account were admins until
  # 2026-09-04; demoting them is what makes admin-only pages, member-facing copy
  # and anything branching on a role have more than one answer available here.
  PARKED_IDENTITIES = [
    { email: "alex@mcritchie.studio",  name: "Alex McRitchie",  role: "admin" },
    { email: "team@mcritchie.studio",  name: "Team McRitchie",  role: "admin" },
    # THE SUPER-ADMIN LANE. admin@mcritchie.studio is the top-of-stack Google
    # credential the Steffon and Alex agents sign in with (1Password
    # `google.studio.admin`, vault `studio-agents-admin`). It is an operator SEAT
    # rather than a person.
    { email: "admin@mcritchie.studio", name: "Admin McRitchie", role: "admin" },
    { email: "mason@mcritchie.studio", name: "Mason McRitchie", role: "viewer" },
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
  # A role demotion reaches an existing row on its next SAVE, because
  # `assign_parked_identity` re-reads the roster by email. Do not read that as
  # "deployed rows converge on their own" — nothing in a release saves them, so
  # the demotion waits for a sign-in that a shared house account may never get.
  # (mack@mcritchie.studio sat in production as an admin for twenty-one days after
  # the roster made him a viewer.) An EMAIL change cannot even do that much:
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

  # Display NAMES the roster planted and has since changed, email => old name.
  #
  # The roster is authoritative for a name only while the row has none:
  # `assign_parked_identity` fills a blank or "anon" name and never overwrites one,
  # because a name someone edited is theirs. So changing a name in
  # PARKED_IDENTITIES renames the literal and no account — which is how
  # "McRitchie Studio Team" would have outlived its own rename. This map is the
  # narrow exception: rewrite the name the ROSTER put there, and only that exact
  # value. Same division of labour as RETIRED_EMAILS — the seed applies it to the
  # databases a re-seed owns, and the data migration spells it out for deployed
  # rows.
  RETIRED_NAMES = {
    "team@mcritchie.studio" => "McRitchie Studio Team"
  }.freeze

  # Passwordless app: email auth is magic-link only, plus Google.
  # has_secure_password stays as a DORMANT fallback (password_digest column) but
  # `validations: false` is required so Google/magic-link users — who have no
  # password — can be created.
  has_secure_password validations: false
  has_one_attached :avatar

  # email is nullable (a Google-only user may have none) and unique when present.
  validates :email, uniqueness: true, allow_nil: true
  validate :has_authentication_method

  before_create :ensure_session_token
  before_validation :assign_parked_identity
  before_save :set_name_parts, if: -> { name_changed? }

  # --- Derived name halves ---------------------------------------------------

  # The halves `set_name_parts` would derive from `name`, as a hash ready for a
  # callback-free write.
  #
  # PUBLIC AND PURE ON PURPOSE. `set_name_parts` is a `before_save`, so a writer
  # that deliberately steps around callbacks used to have no way to keep these
  # columns honest short of a full save it cannot afford. Two such writers exist
  # and both have a reason worth keeping: `db/seeds/01_users.rb` renames with
  # `update_column` because Sluggable rebuilds the slug from the NAME, so a full
  # save re-points the URL the account answers on; the identity migrations rename
  # with raw SQL because loading `User` would drag `assign_parked_identity` and
  # that same slug rewrite into a file that must still run years from now. So the
  # derivation moves to where they can reach it instead of the writers moving to
  # where the derivation is.
  #
  # `last_name` is OMITTED, not nil, for a one-word name. That is not tidiness —
  # it is parity: the callback has always left an existing last name standing
  # there (`if parts.size > 1`), and a hash that nulled it would make every
  # callback-free writer disagree with the callback in the opposite direction.
  # Whether the carry-over is itself right is a separate question from this one.
  # test/models/user_name_parts_test.rb pins the parity for every shape of name.
  def self.name_parts(name)
    words = name.to_s.strip.split(" ")
    parts = { first_name: words.first }
    parts[:last_name] = words.last if words.size > 1
    parts
  end

  # --- Lookups / find-or-create ---------------------------------------------

  def self.parked_identity_for(email: nil)
    normalized_email = email.to_s.strip.downcase.presence
    return nil if normalized_email.blank?

    PARKED_IDENTITIES.find { |identity| identity[:email].to_s.downcase == normalized_email }
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

  def has_email?
    email.present?
  end

  # --- Session token (OPSEC-045) --------------------------------------------

  def regenerate_session_token!
    update!(session_token: SecureRandom.hex(32))
  end

  # --- Display ---------------------------------------------------------------

  def display_name
    name.presence || email&.split("@")&.first&.capitalize || "anon"
  end

  def avatar_initials
    (name.presence || email&.split("@")&.first || "?").first.upcase
  end

  AVATAR_COLORS = %w[#EF4444 #F97316 #EAB308 #22C55E #06B6D4 #3B82F6 #8B5CF6 #EC4899].freeze

  def avatar_color
    key = name.presence || email || id.to_s
    AVATAR_COLORS[Digest::MD5.hexdigest(key).hex % AVATAR_COLORS.size]
  end

  private

  def assign_parked_identity
    identity = self.class.parked_identity_for(email: email)
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


    changed_identity
  end

  def has_authentication_method
    return if email.present? || google_connected?
    errors.add(:base, "must have an email or linked Google account")
  end

  def ensure_session_token
    self.session_token ||= SecureRandom.hex(32)
  end

  def set_name_parts
    assign_attributes(self.class.name_parts(name))
  end

  # Unique URL slug, keyed on the email so two accounts cannot collide.
  #
  # The wallet address used to be the fallback identifier for a wallet-only user.
  # Dropping it changes no EXISTING slug: every row that had a wallet also had an
  # email, and email won this expression already.
  def name_slug
    identifier = email.presence || "user"
    prefix = name.presence || email&.split("@")&.first || "user"
    "#{prefix}-#{identifier}".downcase.gsub(/\s+/, "-")
  end
end
