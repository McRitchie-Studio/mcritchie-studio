class PeopleController < ApplicationController
  skip_before_action :require_authentication, only: [:index, :show]
  before_action :set_person, only: [:show, :create_appearance, :make_default_appearance, :attach_artifact]

  def index
    # Most-recently-touched first: creating or editing a model bumps a person,
    # so the people you are actually working on float to the top rather than
    # whoever happens to be alphabetically first among 3,000.
    @people = Person.includes(:teams, { athlete_profile: :image_caches }, contracts: :team)
                    .order(updated_at: :desc, id: :desc)

    # Model thumbnails for the whole page in ONE query. Per-person lookups here
    # would be 3,000 round trips.
    @models_by_person = ArtifactSubject
                        .joins("INNER JOIN artifacts ON artifacts.slug = artifact_subjects.artifact_slug")
                        .where("artifacts.retired_at IS NULL AND artifacts.image_url IS NOT NULL")
                        .order(Arel.sql("artifacts.created_at DESC"))
                        .pluck(:person_slug, Arel.sql("artifacts.image_url"))
                        .group_by(&:first)
                        .transform_values { |rows| rows.map(&:last) }
  end

  # THE MODEL LIBRARY for one person: every look we have of them, which one is
  # the default, and every image they appear in — including images they share
  # with someone else, which is why this reads through the subject join rather
  # than off the person.
  def show
    @appearances = @person.appearances.live.order(:created_at)
    @artifacts = Artifact.live
                         .joins(:subjects)
                         .where(artifact_subjects: { person_slug: @person.slug })
                         .includes(subjects: [:person, :appearance])
                         .order(created_at: :desc)
                         .distinct
  end

  # Creating a person's FIRST look also makes it their default — the model does
  # that itself (Appearance#become_default_if_first), so this action never has
  # to think about it. It is NOT the only writer: attaching an image at a
  # content's inspection gate files a look too, and stamps the default the same
  # way. A look that goes away releases the slot and a merge re-resolves it on
  # the survivor, so "looks but no default" is an invariant the model holds
  # rather than a state these two paths merely happen to avoid.
  def create_appearance
    appearance = @person.appearances.new(appearance_params)
    rescue_and_log(target: @person) do
      appearance.save!
      redirect_to person_path(@person.slug),
                  notice: "#{appearance.descriptor} saved#{appearance.default? ? ' and set as default' : ''}."
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to person_path(@person.slug), alert: e.message
  end

  def make_default_appearance
    appearance = @person.appearances.live.find_by(slug: params[:appearance_slug])
    return redirect_to(person_path(@person.slug), alert: "No such look.") unless appearance

    appearance.make_default!
    redirect_to person_path(@person.slug), notice: "#{appearance.descriptor} is now the default."
  end

  # Attach an image for one look. A character sheet is a one-subject artifact;
  # multi-person images are created by the content pipeline, not here.
  def attach_artifact
    appearance = @person.appearances.live.find_by(slug: params[:appearance_slug]) || @person.default_appearance
    return redirect_to(person_path(@person.slug), alert: "Create a look first.") unless appearance

    rescue_and_log(target: @person) do
      artifact = Artifact.create!(kind: "character_sheet", image_url: params[:image_url], source: "operator")
      artifact.subjects.create!(person_slug: @person.slug, appearance_slug: appearance.slug, ordinal: 1)
      redirect_to person_path(@person.slug), notice: "Model image attached to #{appearance.descriptor}."
    end
  end

  def search
    query = params[:q].to_s.strip
    people = if query.present?
      Person.where("first_name ILIKE :q OR last_name ILIKE :q OR slug ILIKE :q OR aliases::text ILIKE :q",
                    q: "%#{query}%")
            .order(created_at: :desc)
            .limit(20)
    else
      Person.order(created_at: :desc).limit(10)
    end

    render json: people.map { |p|
      { id: p.id, slug: p.slug, full_name: p.full_name, aliases: p.aliases, teams: p.teams.pluck(:name) }
    }
  end

  def merge
    # Render merge form
  end

  private

  def set_person
    @person = Person.find_by!(slug: params[:slug])
  end

  def appearance_params
    params.require(:appearance).permit(:descriptor, :team_slug, :colorway, :reference_url, :generation_notes)
  end

  public


  def merge_execute
    keep = Person.find_by(slug: params[:keep_slug])
    merge_person = Person.find_by(slug: params[:merge_slug])

    unless keep && merge_person
      return redirect_to merge_people_path, alert: "Both people must be selected."
    end

    if keep == merge_person
      return redirect_to merge_people_path, alert: "Cannot merge a person into themselves."
    end

    rescue_and_log(target: merge_person, parent: keep) do
      perform_merge!(keep, merge_person)
      redirect_to people_path, notice: "Merged #{merge_person.full_name} into #{keep.full_name}."
    end
  rescue StandardError => e
    redirect_to merge_people_path, alert: "Merge failed: #{e.message}"
  end

  def duplicates
    @duplicate_groups = find_duplicate_groups
  end

  private

  def perform_merge!(keep, source)
    # 1. Move contracts
    source.contracts.each do |c|
      existing = Contract.find_by(person_slug: keep.slug, team_slug: c.team_slug)
      if existing
        c.destroy!
      else
        c.update!(person_slug: keep.slug, slug: "#{keep.slug}-#{c.team_slug}")
      end
    end

    # 2. Move roster spots
    source.roster_spots.update_all(person_slug: keep.slug)

    # 3. Move coaches
    source.coaches.each do |c|
      existing = Coach.find_by(person_slug: keep.slug, team_slug: c.team_slug, role: c.role)
      if existing
        c.destroy!
      else
        c.update!(person_slug: keep.slug)
      end
    end

    # 4. Merge athlete profiles
    source_athlete = source.athlete_profile
    keep_athlete = keep.athlete_profile

    if source_athlete
      if keep_athlete
        # Merge draft data into keep's athlete if keep is missing it
        if keep_athlete.draft_pick.nil? && source_athlete.draft_pick.present?
          keep_athlete.update!(
            draft_year: source_athlete.draft_year,
            draft_round: source_athlete.draft_round,
            draft_pick: source_athlete.draft_pick
          )
        end
        # Move athlete grades from source to keep
        source_athlete.grades.each do |g|
          existing = AthleteGrade.find_by(athlete_slug: keep_athlete.slug, season_slug: g.season_slug)
          if existing
            g.destroy!
          else
            g.update!(athlete_slug: keep_athlete.slug)
          end
        end
        # Move pff_stats
        source_athlete.pff_stats.each do |s|
          existing = PffStat.find_by(athlete_slug: keep_athlete.slug, season_slug: s.season_slug, stat_type: s.stat_type)
          if existing
            s.destroy!
          else
            s.update!(athlete_slug: keep_athlete.slug)
          end
        end
        source_athlete.destroy!
      else
        # Re-parent the athlete
        source_athlete.update!(person_slug: keep.slug)
      end
    end

    # 5. Add merged person's name as alias
    alias_name = source.full_name
    unless keep.aliases.include?(alias_name)
      keep.aliases << alias_name
    end
    # Also merge in source's aliases
    source.aliases.each do |a|
      keep.aliases << a unless keep.aliases.include?(a)
    end
    keep.save!

    # 6. Copy boolean flags
    keep.update!(athlete: true) if source.athlete? && !keep.athlete?
    keep.update!(coach: true) if source.coach? && !keep.coach?

    # 7. Move the source's LOOKS and ARTIFACT CAST to the survivor
    relocate_looks_and_cast!(keep, source)

    # 8. Delete merged person
    source.destroy!
  end

  # MERGING TWO PEOPLE MERGES THEIR PICTURES TOO.
  #
  # Without this, the destroy above cascades through
  # `Person has_many :appearances, dependent: :destroy` and
  # `has_many :artifact_subjects, dependent: :destroy`, and the source's looks
  # and cast rows are DELETED rather than inherited. Measured on a throwaway
  # transaction: a pair artifact went from two subjects to one, a character
  # sheet was left with an empty cast label, and the pair's reuse key collapsed
  # to a ONE-PERSON key — so it would match solo lookups it should never match
  # and never again match the pair it actually depicts. Both silent.
  #
  # Both relocations can COLLIDE, and neither collision is a style question:
  # each is a unique index that raises and takes the whole merge down with it.
  def relocate_looks_and_cast!(keep, source)
    relocate_cast!(keep, source)
    relocate_looks!(keep, source)

    # The survivor may have just inherited their FIRST look. Relocation is an
    # UPDATE and Appearance#become_default_if_first is an after_CREATE, so
    # nothing on this path stamps the pointer — measured before the fix: a
    # survivor holding one live look and a nil default, which is precisely the
    # state every read then has to special-case.
    keep.reload.resolve_default_appearance!

    # Drop the cached collections so the destroy that follows cannot cascade
    # into a look or a subject we just handed to the survivor.
    source.association(:appearances).reset
    source.association(:artifact_subjects).reset
  end

  # CAST FIRST, looks second — not interchangeable. The look pass re-points
  # every subject that names a colliding look, so the cast rows have to be on
  # the survivor by then or the ones left behind are destroyed anyway.
  #
  # `index_artifact_subjects_on_artifact_slug_and_person_slug` is unique, so an
  # artifact casting BOTH people cannot take the source's row. After the merge
  # that image depicts one person twice — a cast that never existed — so retire
  # it rather than quietly halving it. Left live with one subject, a `pair`
  # artifact MATCHES a one-person pair lookup, which is the same false match
  # this whole fix exists to prevent.
  def relocate_cast!(keep, source)
    source.artifact_subjects.to_a.each do |subject|
      if ArtifactSubject.exists?(artifact_slug: subject.artifact_slug, person_slug: keep.slug)
        artifact = Artifact.find_by(slug: subject.artifact_slug)
        subject.destroy!
        artifact.retire! if artifact && !artifact.retired?
      else
        subject.update!(person_slug: keep.slug)
      end
    end
  end

  # `index_appearances_live_per_person` is unique on (person_slug, descriptor)
  # among LIVE looks, so a look whose descriptor the survivor already uses
  # cannot simply move — it raises RecordNotUnique and kills the merge.
  #
  # Re-point its subjects at the survivor's twin and drop it. Measured against
  # the alternatives on one probe across three trees: retiring-and-moving it,
  # or moving it under a suffixed name, both leave the artifact keyed to a look
  # no lookup will ever ask for again, so an approved image of the right person
  # in the right outfit goes permanently invisible to Artifact.matching.
  # Re-pointing is the only one of the three where the survivor's own look
  # finds the image — and it is what a merge MEANS: after it, "Joseph in a
  # jersey" simply is "Joe in a jersey".
  def relocate_looks!(keep, source)
    source.appearances.to_a.each do |look|
      twin = look.retired? ? nil : keep.appearances.live.find_by(descriptor: look.descriptor)
      if twin
        ArtifactSubject.where(appearance_slug: look.slug).update_all(appearance_slug: twin.slug)
        look.destroy!
      else
        look.update!(person_slug: keep.slug)
      end
    end
  end

  def find_duplicate_groups
    # Find people who share last_name and have similar first names (Levenshtein ≤ 2)
    groups = []

    # Group athletes by last_name + position
    people_with_athletes = Person.includes(:athlete_profile).where(athlete: true).order(:last_name, :first_name)
    by_last_name = people_with_athletes.group_by(&:last_name)

    by_last_name.each do |last_name, people|
      next if people.size < 2

      people.combination(2).each do |a, b|
        dist = levenshtein(a.first_name.downcase, b.first_name.downcase)
        if dist > 0 && dist <= 2
          groups << { people: [a, b], distance: dist, last_name: last_name }
        end
      end
    end

    groups.sort_by { |g| [g[:distance], g[:last_name]] }
  end

  def levenshtein(a, b)
    m = a.length
    n = b.length
    return n if m == 0
    return m if n == 0

    d = Array.new(m + 1) { Array.new(n + 1, 0) }
    (0..m).each { |i| d[i][0] = i }
    (0..n).each { |j| d[0][j] = j }

    (1..m).each do |i|
      (1..n).each do |j|
        cost = a[i - 1] == b[j - 1] ? 0 : 1
        d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
      end
    end

    d[m][n]
  end
end
