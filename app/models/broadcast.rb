# A marketing email composed + sent from Studio. The branded shell lives in
# layouts/broadcast_email.html.erb; the swappable copy is a view under
# app/views/broadcasts/ keyed by `template_key`. Studio owns the contact list and
# the send (via BroadcastMailer); each recipient gets a BroadcastDelivery that
# tracks opens/clicks.
class Broadcast < ApplicationRecord
  include Sluggable

  STATUSES = %w[draft sent].freeze

  # Links available for click-tracking: key => the column holding the URL.
  # "hero" is the clickable header image.
  TRACKED_LINKS = { "hero" => :hero_url, "survivor" => :survivor_url, "turf_totals" => :turf_totals_url }.freeze

  # Links a template fixes in its copy rather than taking from a column:
  # template_key => { link key => URL }. Tracked like TRACKED_LINKS.
  TEMPLATE_LINKS = {
    # Cyvasse lives on its own domain. Sent emails carry hub tracker links,
    # which resolve this URL at click time (EmailTrackingController#click),
    # so they follow this change. A direct cyvasse.mcritchie.studio link 301s
    # here with its path and ?ref= intact (cyvasse's
    # Cyvasse::CanonicalHostRedirect).
    "cyvasse_is_back" => {
      "play" => "https://cyvasse.xyz/",
      "build" => "https://mcritchie.studio/build"
    }.freeze,
    "cyvasse_your_games" => {
      "play" => "https://cyvasse.xyz/",
      "night" => "https://cyvasse.xyz/night"
    }.freeze
  }.freeze

  # Merge fields a template's body needs (task staged-email-queue): a contact
  # without one is skipped at staging, never rendered with a blank. Fields a
  # subject names (%{username}) are required too; see #required_merge_fields.
  TEMPLATE_MERGE_FIELDS = {
    "cyvasse_your_games" => %w[username games].freeze
  }.freeze

  # Templates whose subject depends on the reader (task tiered-your-games-copy):
  # template_key => a module answering subject_template(fields, default:), where
  # default is the broadcast's stored subject. See #subject_for.
  SUBJECT_RESOLVERS = {
    "cyvasse_your_games" => "Broadcasts::CyvasseYourGames"
  }.freeze

  # Registry of available copy templates: key => human label. Each key maps to
  # a view at app/views/broadcasts/<key>.html.erb.
  TEMPLATES = {
    "world_cup_kickoff"     => "World Cup Kickoff",
    "new_game_announcement" => "New Game Announcement",
    "cyvasse_is_back"       => "Cyvasse Is Back",
    "cyvasse_your_games"    => "Cyvasse: Your Games",
  }.freeze

  has_many :deliveries, class_name: "BroadcastDelivery", dependent: :destroy
  has_many :staged_emails, dependent: :destroy

  validates :subject, presence: true
  validates :template_key, inclusion: { in: TEMPLATES.keys }
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(updated_at: :desc) }

  def template_label
    TEMPLATES[template_key] || template_key
  end

  def status_label
    status.titleize
  end

  def sent?
    status == "sent"
  end

  # Resolve a click-tracking link key to its destination URL (server-side, so the
  # click endpoint can't be turned into an open redirect).
  def link_for(key)
    col = TRACKED_LINKS[key.to_s]
    return public_send(col) if col

    TEMPLATE_LINKS.fetch(template_key, {})[key.to_s]
  end

  # Every link key this broadcast's email can carry.
  def link_keys
    TRACKED_LINKS.keys + TEMPLATE_LINKS.fetch(template_key, {}).keys
  end

  # --- batch sends -----------------------------------------------------------
  # A broadcast can go out in batches (task broadcast-batch-send): each batch
  # takes N random subscribed contacts on the audience who have not yet been
  # sent this broadcast, so a list is worked down gradually and nobody gets it
  # twice. Sends are spaced BATCH_SPACING apart to stay under Resend's rate
  # limit (about 2 a second). A batch leaves the broadcast a draft; the editor's
  # full send still marks it sent.
  BATCH_SPACING = 0.6.seconds

  # Audiences whose sends go only to contacts an email check called valid
  # (task verify-contacts-with-zerobounce). The Cyvasse relaunch's first 101
  # sends hard-bounced 12.9% (13 of 101), so the old player list is mailed
  # verified-only unless a caller says otherwise; catch-all, unknown and
  # unchecked contacts wait. Verify with `contacts:verify`.
  VERIFIED_AUDIENCES = %w[cyvasse-legacy].freeze

  # Whether a send to `audience` is verified-only by default.
  def self.verification_required?(audience)
    VERIFIED_AUDIENCES.include?(audience.to_s)
  end

  # Contacts with a delivery this broadcast actually sent.
  def sent_contact_ids
    deliveries.where.not(sent_at: nil).select(:contact_id)
  end

  # Subscribed contacts on `audience` (a tag, or "all") still to be sent this.
  # `verified: true` keeps only contacts verified valid; nil takes the
  # audience's default (VERIFIED_AUDIENCES).
  def unsent_contacts(audience = target_list, verified: nil)
    verified = self.class.verification_required?(audience) if verified.nil?
    scope = audience.to_s == "all" ? Contact.subscribed : Contact.subscribed.with_tag(audience.to_s)
    scope = scope.verified_valid if verified
    scope.where.not(id: sent_contact_ids)
  end

  # Queue this broadcast to `size` random unsent contacts; returns their ids.
  def send_batch!(size:, audience: target_list, spacing: BATCH_SPACING, verified: nil)
    raise ArgumentError, "no audience: set the broadcast's target list or pass one" if audience.blank?
    raise ArgumentError, "batch size must be positive" unless size.to_i.positive?
    raise ArgumentError, "#{slug} uses merge fields: stage it (broadcasts:stage) and send from the queue" if requires_staging?

    ids = unsent_contacts(audience, verified: verified).order(Arel.sql("RANDOM()")).limit(size.to_i).pluck(:id)
    ids.each_with_index { |contact_id, i| BroadcastSendJob.set(wait: spacing * i).perform_later(id, contact_id) }
    ids
  end

  # Where a batched send stands on `audience`. `remaining` counts only who a
  # batch would take (verified-only where that applies).
  def batch_status(audience = target_list, verified: nil)
    { sent: deliveries.where.not(sent_at: nil).count, remaining: unsent_contacts(audience, verified: verified).count,
      opened: opened_count, clicked: clicked_count }
  end

  # --- staged sends ----------------------------------------------------------
  # A staged send (task staged-email-queue) renders each recipient's email with
  # their merge fields and holds it for review: stage!, then approve, then
  # execute_staged!. See StagedEmail.

  # Every merge field this broadcast needs: those its subject names plus those
  # its template's body uses. A subject's "<key>_count" phrase (MergeFields.
  # with_counts) needs its base count, never a stored "games_count" field.
  def required_merge_fields
    subject_fields = Broadcasts::MergeFields.fields_in(subject).map do |field|
      base = field.delete_suffix("_count")
      Broadcasts::MergeFields::COUNTED.key?(base) ? base : field
    end
    (subject_fields + TEMPLATE_MERGE_FIELDS.fetch(template_key, [])).uniq
  end

  # A personalized broadcast goes out only through the queue: the editor's
  # send and a batch would mail "%{username}" as written.
  def requires_staging?
    required_merge_fields.any?
  end

  # The subject for one reader: the template's resolver picks the line
  # (SUBJECT_RESOLVERS), else the stored subject; then its %{field}s are
  # filled, the "<key>_count" phrases (Broadcasts::MergeFields.with_counts)
  # included.
  def subject_for(fields)
    stored = subject.presence || "(no subject)"
    resolver = SUBJECT_RESOLVERS[template_key]&.constantize
    line = resolver ? resolver.subject_template(fields, default: stored) : stored
    Broadcasts::MergeFields.interpolate(line, Broadcasts::MergeFields.with_counts(fields))
  end

  StageResult = Data.define(:staged, :skipped) do
    def total = staged + skipped
  end

  # Render and hold this broadcast for up to `limit` contacts on `audience`
  # who have neither been sent it nor staged for it; nothing is sent.
  # Idempotent: a contact is staged once (re-render one with StagedEmail#render_snapshot!).
  # The audience rules are Broadcast#unsent_contacts': subscribed only,
  # verified-only where the audience requires it, never someone already sent.
  # `filter` narrows the contacts further: a Hash for `where`, or a callable
  # taking and returning the relation.
  def stage!(audience: target_list, limit: nil, filter: nil, verified: nil, now: Time.current)
    raise ArgumentError, "no audience: set the broadcast's target list or pass one" if audience.blank?

    scope = unsent_contacts(audience, verified: verified).where.not(id: staged_emails.select(:contact_id))
    scope = filter.respond_to?(:call) ? filter.call(scope) : scope.where(filter) if filter.present?
    scope = scope.order(:id)
    scope = scope.limit(limit.to_i) if limit.present?

    staged = skipped = 0
    scope.each do |contact|
      # One transaction per contact: a render that raises leaves no row, never
      # a "staged" email with nothing in it.
      row = transaction(requires_new: true) do
        staged_emails.create!(contact: contact, status: "staged", staged_at: now).render_snapshot!(now: now)
      end
      row.skipped? ? skipped += 1 : staged += 1
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      next # staged by a concurrent run
    end
    StageResult.new(staged: staged, skipped: skipped)
  end

  RestageResult = Data.define(:restaged, :skipped, :left) do
    def total = restaged + skipped
  end

  # Re-render every still-`staged` email with the current template and subject
  # (task tiered-your-games-copy), so a copy fix reaches what is held. Only
  # `staged` rows are touched: an approved, sent, cancelled or skipped row is
  # left exactly as it is. Each row is locked and re-checked first, so one
  # approved while this runs keeps its approval and its snapshot. A reader who
  # now lacks a required field is stored `skipped`, as at staging. `left`
  # counts rows that stopped being staged before their turn.
  def restage!(now: Time.current)
    restaged = skipped = left = 0
    staged_emails.of_status("staged").find_each do |row|
      outcome = transaction(requires_new: true) do
        row.lock!
        next :left unless row.staged?

        row.render_snapshot!(now: now).skipped? ? :skipped : :restaged
      end
      case outcome
      when :restaged then restaged += 1
      when :skipped then skipped += 1
      else left += 1
      end
    end
    RestageResult.new(restaged: restaged, skipped: skipped, left: left)
  end

  # Approve the `count` longest-held staged emails (all of them when nil), or
  # exactly `ids` when given. Returns how many were approved.
  def approve_staged!(count: nil, ids: nil, now: Time.current)
    scope = staged_emails.of_status("staged").order(:staged_at, :id)
    scope = scope.where(id: ids) if ids
    scope = scope.limit(count.to_i) if count
    scope.update_all(status: "approved", approved_at: now, updated_at: now)
  end

  ExecuteResult = Data.define(:queued, :gate)

  # Hand up to `limit` approved staged emails to BroadcastSendJob, spaced for
  # Resend's rate limit, within the daily cap and only while the send gate is
  # open (Broadcasts::SendGate). Each job sends the stored snapshot exactly;
  # the job's per-recipient lock and sent_at check keep it to once.
  def execute_staged!(limit:, spacing: BATCH_SPACING, now: Time.current, gate: Broadcasts::SendGate.status(now: now))
    raise ArgumentError, "limit must be positive" unless limit.to_i.positive?
    return ExecuteResult.new(queued: 0, gate: gate) if gate.paused?

    take = [ limit.to_i, gate.remaining ].min
    queued = 0
    staged_emails.ready_to_send(now).order(:approved_at, :id).limit(take).pluck(:id, :contact_id).each do |staged_id, contact_id|
      # Claim the row first, so two executes can never both queue it.
      next unless StagedEmail.where(id: staged_id, status: "approved", queued_at: nil).update_all(queued_at: now, updated_at: now) == 1

      BroadcastSendJob.set(wait: spacing * queued).perform_later(id, contact_id, staged_id)
      queued += 1
    end
    ExecuteResult.new(queued: queued, gate: gate)
  end

  STAGED_COUNT_KEYS = %w[staged approved sent skipped cancelled].freeze

  # Counts by status for the queue page, plus approved rows already queued.
  def queue_counts
    counts = staged_emails.group(:status).count
    STAGED_COUNT_KEYS.index_with { |s| counts.fetch(s, 0) }
                     .merge("queued" => staged_emails.of_status("approved").where.not(queued_at: nil).count)
  end

  # Why each skipped row was skipped, most common first.
  def skip_reasons
    staged_emails.of_status("skipped").group(:skip_reason).count.sort_by { |_r, n| -n }.to_h
  end

  # --- engagement ------------------------------------------------------------
  def delivered_count = deliveries.count
  def opened_count    = deliveries.where.not(opened_at: nil).count
  def clicked_count   = deliveries.where.not(clicked_at: nil).count

  def open_rate
    delivered_count.zero? ? nil : opened_count.to_f / delivered_count
  end

  def click_rate
    delivered_count.zero? ? nil : clicked_count.to_f / delivered_count
  end

  private

  # Stable random slug (Sluggable rewrites from name_slug on every save).
  def name_slug
    slug.presence || "bcast-#{SecureRandom.hex(6)}"
  end
end
