# HOW A PERSON — OR ONE OF OUR CHARACTERS — LOOKS in a generated image.
#
# OWNED BY EXACTLY ONE OF TWO: a Person (a real human) or a Character (our
# fictional cast: a mascot or a puppet). The `appearances_exactly_one_owner`
# CHECK holds it in the database and `exactly_one_owner` says it in words.
# Everything person-specific below (the athlete's jersey number, the iced twin,
# the recast, the likeness search and identity mint) reads `person` and stays
# person-only: `recastable` and `person_owned` keep character looks out of it.
# What both owners share goes through `owner`.
#
# The generalisation of "colorway". Anchored on Person rather than on a player
# because the hub models PEOPLE: a piece can cast Joe Burrow beside Jim Carrey
# and George Bush, and what differs between them is not who they are but how
# they are presented.
#
# Every person gets a DEFAULT, stamped by whichever write files their first
# look, so the common path never thinks about appearance at all. A variant —
# Burrow in a suit rather than a jersey — is an explicit later choice, and a
# look that is destroyed hands the default back rather than stranding it.
class Appearance < ApplicationRecord
  # THE BOARD RANK READ-MODEL (studio-engine's board primitive), which supplies
  # `board_ordered`, `board_next_position`, the `set_initial_position` genesis seed
  # wired below, and `reposition!` — the 100-gap restamp the shared
  # Studio::Board::Reorderable reorder action on ModelPipelineController delegates to.
  #
  # `board_zone_attr` defaults to :stage, and :stage here is the OPERATOR'S HAND
  # PLACEMENT rather than the lane a card renders in (which is derived —
  # Appearances::LookReading). That distinction is deliberate and costs nothing: the
  # zone is read only by `set_initial_position`, and a look nobody has dragged has a
  # NULL stage, so its genesis rank is seeded globally and lands on top. `reposition!`
  # never reads the zone — it stamps the ids the drag handed it, in the order it handed
  # them — so the rank a lane actually carries is always written by a real drag in that
  # lane.
  include Studio::Board::Rankable

  # THE FIVE LANES, owned by Appearances::LookReading because the ORDER of them is the
  # pipeline rule (a hand placement may not move a look behind its evidence) and the
  # rule and the list must not live in two places. Named here so a validation and a
  # form can reach it the way every other staged record in this app does.
  STAGES = Appearances::LookReading::STAGES

  belongs_to :person, foreign_key: :person_slug, primary_key: :slug, inverse_of: :appearances, optional: true
  belongs_to :character, foreign_key: :character_slug, primary_key: :slug, inverse_of: :appearances, optional: true
  belongs_to :team, foreign_key: :team_slug, primary_key: :slug, optional: true
  # A music-video look: this artist as they appear in one video (music video
  # pipeline, stage 4). Nil on athlete looks.
  belongs_to :music_video, foreign_key: :music_video_slug, primary_key: :slug, optional: true
  has_many :artifact_subjects, foreign_key: :appearance_slug, primary_key: :slug, dependent: :nullify

  # THE ICED-OUT TWIN. Every look a person is given gets a twin that is its own
  # look (so the recast picker lists it, "Cowboys white · iced") and builds its
  # sheet from the iced prompt. `iced` marks the twin; `base_appearance_slug`
  # names the look it was made from. Appearances::IcedTwin makes them.
  belongs_to :base_appearance, class_name: "Appearance", foreign_key: :base_appearance_slug,
             primary_key: :slug, optional: true, inverse_of: :iced_twins
  has_many :iced_twins, -> { live }, class_name: "Appearance", foreign_key: :base_appearance_slug,
           primary_key: :slug, inverse_of: :base_appearance, dependent: :nullify

  # THE PHOTOGRAPHS WE FOUND OF THIS PERSON, chosen and rejected both. DESTROYED
  # with the look rather than nullified, unlike the artifacts above: an artifact is
  # a picture that outlives the look it was filed under, while a candidate
  # photograph means nothing without the look whose identity it was judged for.
  has_many :reference_photos, class_name: "AppearanceReferencePhoto",
           foreign_key: :appearance_slug, primary_key: :slug,
           inverse_of: :appearance, dependent: :destroy

  validates :slug, presence: true, uniqueness: true
  validates :descriptor, presence: true
  validate :exactly_one_owner
  # A LOOK MAY NOT NAME A TEAM THAT IS NOT ON FILE. `belongs_to :team` above is
  # optional and keyed by slug, so a slug with no row resolves to nil and reads
  # everywhere as "no team": the first real TikTok draft (2026-10-08) was
  # refused "has no team" for a look that said dallas-cowboys, because
  # production's teams table was empty. Checked on create and when the slug
  # changes ONLY, so a row that already carries a dangling slug still saves for
  # an unrelated edit (its jersey number, its stage).
  validate :team_slug_names_a_team, if: -> { team_slug.present? && (new_record? || team_slug_changed?) }

  # NULL IS A REAL AND COMMON VALUE: "nobody has ever dragged this look". It is not
  # the same as "designed", and `allow_nil` is what keeps the two distinguishable —
  # every look on file predates the board and asserts no hand placement.
  validates :stage, inclusion: { in: STAGES }, allow_nil: true
  # The number this look wears (piece 16): clip prompts name the player as
  # "#4 Dak Prescott". Per look, not per person: a throwback can wear another.
  JERSEY_NUMBERS = (0..99)
  validates :jersey_number, numericality: { only_integer: true, in: JERSEY_NUMBERS }, allow_nil: true

  before_validation :generate_slug, on: :create
  before_validation :normalize_colorway
  before_validation :take_the_athletes_number, on: :create
  before_create :set_initial_position
  after_create :become_default_if_first
  before_destroy :remember_default_holders
  before_destroy :remember_recasts
  after_destroy :release_default_pointer
  after_destroy :release_recasts

  scope :live, -> { where(retired_at: nil) }
  # Looks an on-screen performer can be recast INTO: live, and not themselves a
  # capture of a performer in some video (a music-video look).
  # Person-owned only: a puppet in a Recast video is piece D of the Characters
  # addendum, not something a recast picker may offer by accident.
  scope :recastable, -> { live.where(music_video_slug: nil).person_owned }
  scope :person_owned, -> { where.not(person_slug: nil) }
  scope :character_owned, -> { where.not(character_slug: nil) }

  def to_param = slug
  def retired? = retired_at.present?

  def music_video_look? = music_video_slug.present?

  # The look names a team (team_slug) that has no row in `teams`, so `team` is
  # nil though a team was meant. Not the same as carrying no team.
  def team_missing? = team_slug.present? && !Team.exists?(slug: team_slug)

  # WHO WEARS THIS LOOK: the Person or the Character, whichever is set.
  def owner = character_owned? ? character : person
  def character_owned? = character_slug.present?
  def person_owned? = person_slug.present?

  # The name a prompt or a page names the owner by: a person's full name, a
  # character's name, or the slug when the owner row is gone.
  def owner_name
    named = character_owned? ? character&.name : person&.full_name
    named.presence || (character_slug || person_slug).to_s.titleize.presence
  end

  # The live iced twin of this (base) look, or nil.
  def iced_twin = iced_twins.first

  # The character-sheet build (Appearances::SheetBuild owns the rules).
  def sheet_build_stale?
    sheet_build_state == Appearances::SheetBuild::BUILDING &&
      (sheet_build_started_at.nil? || sheet_build_started_at < Appearances::SheetBuild::STALE_AFTER.ago)
  end

  def sheet_building? = sheet_build_state == Appearances::SheetBuild::BUILDING && !sheet_build_stale?
  def sheet_build_failed? = sheet_build_state == Appearances::SheetBuild::FAILED
  def sheet_build_done? = sheet_build_state == Appearances::SheetBuild::DONE

  # Seconds the build ran, or has run so far.
  def sheet_build_seconds
    return unless sheet_build_started_at

    ((sheet_build_finished_at || Time.current) - sheet_build_started_at).round
  end

  # The on-screen performer a music-video look was built from.
  def video_performer
    return unless music_video_look?

    @video_performer ||= VideoPerformer.find_by(music_video_slug:, ordinal: performer_ordinal)
  end

  def default?
    owner&.default_appearance_slug == slug
  end

  def make_default!
    owner&.update!(default_appearance_slug: slug)
  end

  # What an image generator works from. An athlete's physical description comes
  # free off the Athlete record; for anyone with no role record the notes are
  # the only source, which is why they live here rather than on Person — the
  # same face in two eras is two looks, not one.
  def generation_brief
    [descriptor, person&.athlete_profile&.physical_brief, generation_notes]
      .compact_blank.join("\n")
  end

  # MAY A GENERATION NAME THIS LOOK'S HIGGSFIELD IDENTITY YET?
  #
  # An identity is minted `not_ready` and walks `queued` → `in_progress` →
  # `completed` (measured 2026-09-24 by creating a real one and polling it to
  # rest). Pinning a generation to one that is still training spends money on a
  # face nobody waited for, so the question has to be asked before every pin.
  #
  # POSITIVE FORM DELIBERATELY: this is true only for the one status we have
  # OBSERVED to mean success. The tempting inverse — "not one of the pending
  # words" — reads every status we have never seen, including whatever the API
  # says when the reference FAILS, as ready. `fail_reason` is a second signal
  # and this needs neither of them: an unrecognised word is not a yes.
  def higgsfield_reference_ready?
    higgsfield_reference_id.present? &&
      higgsfield_reference_status == Appearances::CreateCharacterReference::READY_STATUS
  end

  # Still becoming one. Distinct from "never asked for" (no id at all) and from
  # "the vendor said something we do not recognise", because only this state is
  # worth polling again.
  def higgsfield_reference_pending?
    higgsfield_reference_id.present? &&
      Appearances::CreateCharacterReference::PENDING_STATUSES.include?(higgsfield_reference_status)
  end

  # HOW MANY PHOTOGRAPHS THE IDENTITY WOULD BE BUILT FROM RIGHT NOW.
  #
  # Asked through Appearances::ReferenceSet rather than counted off
  # `reference_photos`, because the floor — the cached headshot and the operator's
  # URL — is derived rather than filed. Counting the table alone would report 0 for
  # every look that has never been searched, which is exactly the look the operator
  # opens first.
  def reference_photo_count = Appearances::ReferenceSet.call(self).length

  # ONE WORD FOR THE PAGE'S STATUS CHIP, and it is not the raw column.
  #
  # The column is nil for a look nobody has minted, and may hold a word the vendor
  # invented that we have never seen. Both are real states the page must name, and
  # neither has a value in the column to name it with — so the mapping lives here
  # instead of as a chain of conditionals in the view.
  def higgsfield_reference_state
    return :none if higgsfield_reference_id.blank?
    return :ready if higgsfield_reference_ready?
    return :pending if higgsfield_reference_pending?

    :unknown
  end

  def display_label
    [descriptor, (default? ? "(default)" : nil)].compact.join(" ")
  end

  # "#4", or nil without a number.
  def jersey_label = jersey_number.nil? ? nil : "##{jersey_number}"

  # A typed jersey number as the column takes it: "04" -> 4, blank -> nil.
  # Anything else is kept as typed, so the validation names it.
  def self.jersey_from(value)
    text = value.to_s.strip
    return nil if text.empty?

    text.match?(/\A\d{1,2}\z/) ? text.to_i : text
  end

  # THE LOOK AN ATTACH FILES.
  #
  # Uploading an image for a named colorway is a STATEMENT about how this person
  # looks in it, so the attach files that look rather than leaving the row
  # unattributed. Filing nil instead is what made an attached artifact
  # unfindable: the row went in under "no look" while every read resolves nil to
  # the person's DEFAULT (ArtifactSubject#effective_appearance), so the reuse key
  # asked for `person@` and found `person@<default>`.
  #
  # IDEMPOTENT on the colorway, which is what lets the attach run on every
  # upload without accumulating looks. It rests on the find_by ALONE — there is
  # no unique index on (person_slug, colorway), only the partial one on
  # (person_slug, descriptor).
  #
  # SETS THE DEFAULT when this is the person's first look, because
  # `become_default_if_first` fires on the create. So an ATTACH can stamp a
  # person's default, and every nil-appearance row already on file for them
  # re-resolves to it. That is correct rather than incidental: with no colorway
  # named, the plan reads `person.default_appearance` and a nil row's fallback
  # reads the same expression, so the two move together. A read that NAMES a
  # colorway does not move with them — and should not, because it correctly
  # drops to :reskin rather than reusing a colorway-less artifact for a named
  # jersey.
  #
  # A retired look in that colorway is not revived; a fresh one is filed beside
  # it, and the partial index (`where retired_at IS NULL`) leaves the old name
  # free. Nothing in the app retires a look yet — this is the behaviour that
  # will be right when something does. Whoever builds that inherits one more
  # thing, so do not read the sentence above as "the ground has been checked":
  # retiring a look does NOT release the artifacts filed under it, because
  # ArtifactSubject#effective_appearance reads the association rather than
  # `live`. The row keeps naming the retired look while the plan moves on to a
  # surviving one, and the artifact goes unfindable — the same write/read skew
  # this method exists to close, reached through a different door.
  #
  # Returns nil when nothing names a colorway. Nothing is filed, and the nil
  # write is still correct — not because the person has no looks (they may, and
  # a pointer a RAW delete orphaned still reads as none until their next look
  # resolves it; the destroy and merge routes now release it themselves) but
  # because with no colorway named the plan reads `person.default_appearance`
  # and the row's fallback reads that same expression. The two agree by
  # construction.
  #
  # THAT AGREEMENT IS NOT PERMANENT, and reading this as "nil is always safe"
  # is how the second half of the defect survived. The two nils mean the same
  # thing only while nothing names a colorway. Confirm the jersey afterwards —
  # ContentsController#set_colorway, one click — and the request's nil starts
  # meaning "nothing on file satisfies this" while the row's still means
  # "nobody recorded it", and both render `person@`. This IS the only route
  # left to an unattributed row, so it is where Artifact.matching's colorway
  # refusal earns its place; a reader who concludes that refusal is now dead
  # code would be wrong.
  def self.file_for_colorway!(person_slug:, colorway:)
    colorway = colorway.to_s.strip.downcase.presence
    return nil if colorway.blank? || person_slug.blank?

    live.find_by(person_slug: person_slug, colorway: colorway) ||
      create!(person_slug: person_slug, colorway: colorway,
              descriptor: available_descriptor(person_slug, descriptor_base(colorway)))
  end

  # COLORWAY IS FREE TEXT — the jersey field at the inspection gate takes
  # whatever the operator types — so `titleize` is not safe to use bare here.
  # It returns "" for anything that is all punctuation ("_" and "-" both do),
  # which fails the descriptor presence validation and raises RecordInvalid
  # mid-attach; `rescue_and_log` re-raises, so the operator got an error page
  # rather than their image. Fall back to the raw colorway, which is already
  # known non-blank by the guard above.
  def self.descriptor_base(colorway)
    colorway.titleize.presence || colorway
  end
  private_class_method :descriptor_base

  # `index_appearances_live_per_person` is UNIQUE on (person_slug, descriptor)
  # among live looks, so a person who already has a hand-named "Primary" in some
  # other colorway would make the create above raise RecordNotUnique rather than
  # file anything. Step past the taken names instead of failing the attach.
  def self.available_descriptor(person_slug, base)
    candidate = base
    suffix = 2
    while live.exists?(person_slug: person_slug, descriptor: candidate)
      candidate = "#{base} #{suffix}"
      suffix += 1
    end
    candidate
  end

  private

  # A new look with no number typed wears the athlete's roster number
  # (athletes.jersey_number) when there is one; the operator edits it on the
  # person page when this look wears another. A plain query, NOT
  # person.athlete_profile: loading the association here would cache it on the
  # caller's Person, and a later read (GatherReferencePhotos' team) would see
  # the stale row instead of one updated since.
  def take_the_athletes_number
    return unless jersey_number.nil? && person_slug.present?

    roster = Athlete.where(person_slug:).pick(:jersey_number)
    # A roster number the look cannot wear (bad feed data) is no number, never a
    # refused look.
    self.jersey_number = roster if roster.is_a?(Integer) && JERSEY_NUMBERS.cover?(roster)
  end

  # The FIRST look a person gets becomes their default. Doing it here rather
  # than at a call site means a person can never end up with looks and no
  # default, which is the state every lookup would have to special-case.
  def become_default_if_first
    owner&.resolve_default_appearance!
  end

  # A LOOK THAT GOES AWAY HANDS THE SLOT ON.
  #
  # `people.default_appearance_slug` and `characters.default_appearance_slug`
  # carry a foreign key with ON DELETE SET NULL,
  # so the DELETE itself clears every pointer aimed at this look, and by
  # after_destroy no row names it any more. The holders are read before the
  # delete (scoped by the COLUMN, since anyone may hold it, not only #person) and
  # each is re-pointed at its oldest surviving live look afterwards.
  def remember_default_holders
    @default_holder_ids = [Person, Character].to_h { |owners| [owners.name, owners.where(default_appearance_slug: slug).pluck(:id)] }
  end

  def release_default_pointer
    [Person, Character].each do |owners|
      owners.where(id: Array((@default_holder_ids || {})[owners.name])).find_each(&:resolve_default_appearance!)
    end
  end

  def team_slug_names_a_team
    errors.add(:base, "The look #{Team.missing_phrase(team_slug)}") if team_missing?
  end

  def exactly_one_owner
    return if person_slug.present? ^ character_slug.present?

    errors.add(:base, "A look belongs to exactly one person or one character")
  end

  # A recast that named this look keeps its athlete and loses the look (the
  # card asks for another), and the videos' prompts stop mentioning it.
  # video_performers.recast_appearance_slug carries a foreign key with ON DELETE
  # SET NULL, so the recasts are released before the delete, while they can still
  # be found by this slug, and their videos' prompts refreshed after it.
  def remember_recasts
    recasts = VideoPerformer.where(recast_appearance_slug: slug)
    @recast_videos = recasts.distinct.pluck(:music_video_slug)
    recasts.update_all(recast_appearance_slug: nil, updated_at: Time.current) if @recast_videos.any?
  end

  def release_recasts
    MusicVideo.where(slug: Array(@recast_videos)).find_each { |video| MusicVideos::ClipPrompts.refresh!(video) }
  end

  def normalize_colorway
    self.colorway = colorway.to_s.strip.downcase.presence
  end

  def generate_slug
    self.slug ||= "look-#{SecureRandom.hex(6)}"
  end
end
