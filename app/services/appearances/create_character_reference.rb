module Appearances
  # MINT A HIGGSFIELD CHARACTER IDENTITY FOR ONE LOOK, and record it.
  #
  # The difference this buys: "generate a picture of a quarterback" invents a new
  # face every call, while a generation pinned to a character identity renders
  # THIS person, from these reference photos, consistently across every shot.
  #
  # TWO COLLABORATORS, BOTH INJECTED, for different reasons:
  #
  #   `references` — WHICH PHOTOS the identity is built from. Injected because
  #   that list is the part that grows: today it is the cached ESPN headshot
  #   (plus an operator-supplied URL when there is one), tomorrow an image-search
  #   step adds a profile, a back view and a few expressions. See
  #   Appearances::ReferenceImages for the contract a replacement implements.
  #
  #   `client` — the vendor. Injected because every call to it costs real money,
  #   so the unit suite must be able to hand this object something that cannot
  #   reach the network. Built LAZILY, not in the initializer: Higgsfield::Client
  #   raises when the credential is absent, and a service that cannot be
  #   INSTANTIATED without a production key is a service that cannot be tested
  #   on a laptop.
  class CreateCharacterReference
    # Nothing to build an identity from. Raised rather than returning nil so the
    # caller cannot mistake "we have no photographs of this person" for "the
    # vendor turned us down" — the remedies are completely different.
    class NoReferenceImages < StandardError; end

    # WHAT THE VENDOR CALLS BACK, measured end-to-end on 2026-09-24 by creating a
    # real reference and polling it to rest:
    #
    #   not_ready -> queued -> in_progress -> completed
    #
    # `not_ready` is what the CREATE returns, so an identity is never usable at
    # the moment it is recorded. `completed` is the terminal success and the only
    # state in which a generation should name this id. `fail_reason` stays null
    # throughout a healthy run and is the signal for the unhappy one.
    #
    # `thumbnail_url` was STILL null at `completed`, so it is not a readiness
    # signal despite looking like one.
    STATUS_REQUESTED = "not_ready".freeze
    READY_STATUS = "completed".freeze

    # States we have SEEN the vendor pass through on the way to ready. Named
    # exhaustively rather than inferred as "anything that is not ready", because
    # a status word we have never seen is more likely a failure than a success,
    # and Appearance#higgsfield_reference_ready? must not read it as one.
    PENDING_STATUSES = %w[not_ready queued in_progress].freeze

    def initialize(appearance, client: nil, references: ReferenceImages)
      @appearance = appearance
      @client = client
      @references = references
    end

    # IDEMPOTENT BY DEFAULT. A look that already carries an identity returns it
    # untouched — this runs from operator screens and background work, and a
    # second click must not pay for a second identity, nor orphan the first (we
    # store one id per look, so a re-create would overwrite the pointer and leave
    # the old identity alive on the vendor's side with nothing naming it; there
    # is no list endpoint, so it could never be found again).
    #
    # `force: true` is the deliberate rebuild — the reference list grew and the
    # operator wants the identity remade from it. It accepts that cost knowingly.
    def call(force: false)
      existing = @appearance.higgsfield_reference_id
      return existing if existing.present? && !force

      urls = Array(@references.call(@appearance))
      if urls.empty?
        raise NoReferenceImages,
              "#{@appearance.slug} has no reference photographs — no cached headshot and no " \
              "reference_url — so there is nothing to build a character identity from"
      end

      id = client.create_custom_reference(name: reference_name, image_urls: urls)
      @appearance.update!(
        higgsfield_reference_id: id,
        higgsfield_reference_status: STATUS_REQUESTED,
        higgsfield_reference_synced_at: Time.current
      )
      id
    end

    # ASK THE VENDOR WHERE THE IDENTITY GOT TO, and write the answer down.
    #
    # Without this the stored status is a permanent lie: the create stamps
    # `not_ready` and nothing else ever moves it, so a column that exists to
    # answer "may we pin a generation to this yet?" would always answer no.
    #
    # Returns the status it settled on, or nil when the look has no identity.
    def refresh_status!
      id = @appearance.higgsfield_reference_id
      return nil if id.blank?

      payload = client.custom_reference(id)
      status = payload["status"].presence
      @appearance.update!(
        higgsfield_reference_status: status,
        higgsfield_reference_synced_at: Time.current
      )
      status
    end

    private

    def client = @client ||= Higgsfield::Client.new

    # FOR HUMAN EYES ON THE VENDOR'S SIDE ONLY — nothing reads it back. There is
    # no list endpoint (`GET /v1/custom-references` answers 405, measured
    # 2026-09-24), so the id we store is the only handle that survives; the name
    # exists so a person looking at their dashboard can tell two identities
    # apart. It carries the look's slug for exactly that reason.
    #
    # Empty names are accepted by the API, so this cannot fail the create.
    def reference_name
      [@appearance.person_slug, @appearance.descriptor, "(#{@appearance.slug})"]
        .compact_blank.join(" ")
    end
  end
end
