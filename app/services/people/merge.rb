# Merges one Person (the source) into another (the keeper) and destroys the
# source: the one merge both the people page (PeopleController#merge_execute) and
# the duplicate sweep (Athletes::MergeDuplicates) run.
#
# Every row that names the source moves to the keeper, or is dropped where the
# keeper already holds its twin (the unique indexes decide what a twin is). A
# moved row whose own slug is built from the person's (a contract, a coach, an
# athlete profile, and the grades, stats and rankings built on those) takes the
# slug its new parent derives, through rename_slug!, so no row keeps the
# merged-away person's name in its slug and a later person of that name never
# collides with it.
#
# All of it runs in one transaction. A refusal anywhere (a slug taken, a key that
# still points at the source) rolls the whole merge back and raises; the caller
# answers it with the reason.
class People::Merge
  attr_reader :keep, :source, :stats

  def self.call!(keep:, source:) = new(keep: keep, source: source).call!

  def initialize(keep:, source:)
    raise ArgumentError, "cannot merge a person into themselves" if keep == source

    @keep = keep
    @source = source
    @stats = Hash.new(0)
  end

  def call!
    Person.transaction do
      move_athlete_profile
      move_contracts
      move_coaches
      move_roster_spots
      move_depth_chart_entries
      relocate_looks_and_cast
      move_plain_pointers
      merge_identity
      source.destroy!
    end
    stats
  end

  private

  # --- sports records --------------------------------------------------------

  def move_athlete_profile
    source_athlete = source.athlete_profile
    return unless source_athlete

    keep_athlete = keep.athlete_profile
    unless keep_athlete
      source_athlete.update!(person_slug: keep.slug)
      resettle_athlete(source_athlete)
      stats[:athlete_profiles_moved] += 1
      return
    end

    if keep_athlete.draft_pick.nil? && source_athlete.draft_pick.present?
      keep_athlete.update!(draft_year: source_athlete.draft_year, draft_round: source_athlete.draft_round,
                           draft_pick: source_athlete.draft_pick)
    end
    move_rows(AthleteGrade.where(athlete_slug: source_athlete.slug), :grades) do |grade|
      next :dropped if AthleteGrade.exists?(athlete_slug: keep_athlete.slug, season_slug: grade.season_slug)

      grade.update!(athlete_slug: keep_athlete.slug)
      resettle(grade)
    end
    move_rows(PffStat.where(athlete_slug: source_athlete.slug), :pff_stats) do |stat|
      next :dropped if PffStat.exists?(athlete_slug: keep_athlete.slug, season_slug: stat.season_slug, stat_type: stat.stat_type)

      stat.update!(athlete_slug: keep_athlete.slug)
      resettle(stat)
    end
    move_rows(ImageCache.where(owner: source_athlete), :image_caches) do |cache|
      next :dropped if ImageCache.exists?(owner: keep_athlete, purpose: cache.purpose, variant: cache.variant)

      cache.update!(owner: keep_athlete)
    end
    source_athlete.reload.destroy!
  end

  def move_contracts
    move_rows(Contract.where(person_slug: source.slug), :contracts) do |contract|
      next :dropped if Contract.exists?(person_slug: keep.slug, team_slug: contract.team_slug)

      contract.update!(person_slug: keep.slug)
      resettle(contract)
    end
  end

  def move_coaches
    move_rows(Coach.where(person_slug: source.slug), :coaches) do |coach|
      twin = Coach.find_by(person_slug: keep.slug, team_slug: coach.team_slug, role: coach.role)
      if twin
        move_coach_rankings(coach, twin)
        next :dropped
      end

      coach.update!(person_slug: keep.slug)
      resettle(coach)
      coach.coach_rankings.each { |ranking| resettle(ranking) }
    end
  end

  def move_coach_rankings(coach, twin)
    move_rows(coach.coach_rankings, :coach_rankings) do |ranking|
      next :dropped if CoachRanking.exists?(coach_slug: twin.slug, rank_type: ranking.rank_type, season_slug: ranking.season_slug)

      ranking.update!(coach_slug: twin.slug)
      resettle(ranking)
    end
  end

  def move_roster_spots
    move_rows(RosterSpot.where(person_slug: source.slug), :roster_spots) do |spot|
      next :dropped if RosterSpot.exists?(roster_id: spot.roster_id, person_slug: keep.slug, position: spot.position)

      spot.update!(person_slug: keep.slug)
    end
  end

  def move_depth_chart_entries
    move_rows(DepthChartEntry.where(person_slug: source.slug), :depth_chart_entries) do |entry|
      next :dropped if DepthChartEntry.exists?(depth_chart_slug: entry.depth_chart_slug, person_slug: keep.slug,
                                               position: entry.position)

      entry.update!(person_slug: keep.slug)
    end
  end

  # Moves each row of `scope` with the block, or destroys it when the block
  # answers :dropped (the keeper already holds its twin), and counts both.
  def move_rows(scope, name)
    scope.to_a.each do |row|
      if yield(row) == :dropped
        row.reload.destroy!
        stats[:"#{name}_dropped"] += 1
      else
        stats[:"#{name}_moved"] += 1
      end
    end
  end

  # The row takes the slug its (new) parent derives, cascading to its children.
  def resettle(record)
    record.rename_slug!(record.name_slug)
  end

  def resettle_athlete(athlete)
    resettle(athlete)
    athlete.grades.each { |grade| resettle(grade) }
    athlete.pff_stats.each { |stat| resettle(stat) }
  end

  # --- pictures ---------------------------------------------------------------
  #
  # Merging two people merges their pictures too. Without this, the destroy
  # cascades through `has_many :appearances, dependent: :destroy` and
  # `has_many :artifact_subjects, dependent: :destroy`, deleting the source's looks
  # and cast rows instead of handing them to the keeper. Each relocation can
  # collide with a unique index; each collision is resolved below.

  def relocate_looks_and_cast
    relocate_cast
    recast_videos = relocate_recasts
    relocate_looks

    # Relocation is an UPDATE and Appearance#become_default_if_first runs after
    # create, so the keeper's first inherited look gets its default stamped here.
    keep.reload.resolve_default_appearance!

    # Drop the cached collections so the destroy cannot cascade into a look or a
    # subject just handed to the keeper.
    source.association(:appearances).reset
    source.association(:artifact_subjects).reset
    source.association(:recast_performers).reset
    MusicVideo.where(slug: recast_videos).find_each { |video| MusicVideos::ClipPrompts.refresh!(video) }
  end

  # On-screen performers the source replaces now name the keeper; returns the
  # videos touched, whose prompts are refreshed once the looks have moved too.
  def relocate_recasts
    recasts = VideoPerformer.where(recast_person_slug: source.slug)
    videos = recasts.distinct.pluck(:music_video_slug)
    stats[:recasts_moved] += recasts.update_all(recast_person_slug: keep.slug, updated_at: Time.current)
    videos
  end

  # `index_artifact_subjects_on_artifact_slug_and_person_slug` is unique, so an
  # artifact casting both people cannot take the source's row. That image would
  # then depict one person twice, a cast that never existed, so it is retired
  # rather than quietly halved.
  def relocate_cast
    source.artifact_subjects.to_a.each do |subject|
      if ArtifactSubject.exists?(artifact_slug: subject.artifact_slug, person_slug: keep.slug)
        artifact = Artifact.find_by(slug: subject.artifact_slug)
        subject.destroy!
        artifact.retire! if artifact && !artifact.retired?
        stats[:cast_retired] += 1
      else
        subject.update!(person_slug: keep.slug)
        stats[:cast_moved] += 1
      end
    end
  end

  # `index_appearances_live_per_person` is unique on (person_slug, descriptor)
  # among live looks, so a look whose descriptor the keeper already uses cannot
  # move. Its subjects, recasts and iced twin re-point at the keeper's look and it
  # is dropped: after the merge "Joseph in a jersey" simply is "Joe in a jersey",
  # and the approved image stays findable through the keeper's own look.
  def relocate_looks
    source.appearances.to_a.each do |look|
      twin = look.retired? ? nil : keep.appearances.live.find_by(descriptor: look.descriptor)
      if twin
        ArtifactSubject.where(appearance_slug: look.slug).update_all(appearance_slug: twin.slug)
        VideoPerformer.where(recast_appearance_slug: look.slug).update_all(recast_appearance_slug: twin.slug)
        # Its iced twin follows it unless the keeper's look already has one (then
        # the source's twin goes unlinked, not lost).
        Appearance.where(base_appearance_slug: look.slug).update_all(base_appearance_slug: twin.slug) unless twin.iced_twin
        look.destroy!
        stats[:looks_dropped] += 1
      else
        look.update!(person_slug: keep.slug)
        stats[:looks_moved] += 1
      end
    end
  end

  # --- the rest ---------------------------------------------------------------

  # Columns that name a person with no uniqueness to resolve: they follow the
  # keeper as they are.
  def move_plain_pointers
    now = Time.current
    stats[:jewelries_moved] += PersonJewelry.where(person_slug: source.slug).update_all(person_slug: keep.slug, updated_at: now)
    stats[:artists_moved] += Artist.where(person_slug: source.slug).update_all(person_slug: keep.slug, updated_at: now)
    %i[primary_person_slug secondary_person_slug].each do |column|
      stats[:news_moved] += News.where(column => source.slug).update_all(column => keep.slug, updated_at: now)
    end
    stats[:builders_moved] += Builder.where(person_id: source.id).update_all(person_id: keep.id, updated_at: now)
  end

  def merge_identity
    keep.aliases = (keep.aliases + [source.full_name] + source.aliases).compact_blank.uniq
    keep.athlete = true if source.athlete?
    keep.coach = true if source.coach?
    keep.vocations = keep.vocations | source.vocations
    keep.save!
  end
end
