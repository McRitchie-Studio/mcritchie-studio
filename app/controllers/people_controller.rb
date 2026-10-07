class PeopleController < ApplicationController
  # ADMIN, NOT MERELY A SESSION, on every action here that writes. Hub signup is
  # open, so a session costs a stranger one email address: it is no control over
  # who may file a look, move a default, plant a picture or merge two people.
  # Before set_person, so a refused request costs no lookup.
  before_action :require_admin, only: [:create_appearance, :update_appearance, :create_iced_twin, :make_default_appearance,
                                       :attach_artifact, :update_vocations, :merge_execute, :edit_slug, :update_slug]
  before_action :set_person, only: [:show, :create_appearance, :update_appearance, :create_iced_twin, :make_default_appearance,
                                    :attach_artifact, :update_vocations, :edit_slug, :update_slug]

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
                        .where.not(person_slug: nil)
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
    @appearances = twins_beside_bases(@person.appearances.live.order(:created_at).to_a)
    @twinned_slugs = @appearances.filter_map { |look| look.base_appearance_slug if look.iced? }.to_set
    @jewelries = @person.jewelries.to_a
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
  #
  # EVERY NEW LOOK GETS ITS ICED-OUT TWIN (Appearances::IcedTwin), in the same
  # transaction. Only the rows: neither sheet is built here, so nothing spends.
  def create_appearance
    appearance = @person.appearances.new(appearance_params)
    rescue_and_log(target: @person) do
      twin = Appearance.transaction do
        appearance.save!
        Appearances::IcedTwin.create!(appearance)
      end
      redirect_to recast_return_path || person_path(@person.slug),
                  notice: "#{appearance.descriptor} saved#{appearance.default? ? ' and set as default' : ''}, " \
                          "with its iced twin #{twin.descriptor}. No sheet was built."
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to person_path(@person.slug, return_to: recast_return_path), alert: e.message
  end

  # Edit one look's jersey number (piece 16), the number clip prompts name the
  # player by. Blank clears it. The stored prompts of every source that casts
  # this look are refilled; an alt video's prompts are built when shown.
  def update_appearance
    look = @person.appearances.live.find_by(slug: params[:appearance_slug])
    return redirect_to(person_path(@person.slug), alert: "No such look.") unless look

    look.jersey_number = Appearance.jersey_from(params.dig(:appearance, :jersey_number))
    return redirect_to(person_path(@person.slug), alert: look.errors.full_messages.to_sentence) unless look.valid?

    rescue_and_log(target: look) do
      look.save!
      MusicVideos::ClipPrompts.refresh_casting!(look)
    end
    redirect_to person_path(@person.slug),
                notice: "#{look.descriptor}: #{look.jersey_label ? "wears #{look.jersey_label}" : 'no jersey number'}."
  end

  # "Create iced twin" on a look made before twins existed (no backfill). Free:
  # a row, no sheet. Idempotent, so a second press finds the first twin.
  def create_iced_twin
    base = @person.appearances.live.find_by(slug: params[:appearance_slug])
    return redirect_to(person_path(@person.slug), alert: "No such look.") unless base

    refusal = Appearances::IcedTwin.refusal(base)
    return redirect_to(person_path(@person.slug), alert: "No iced twin made: #{refusal}.") if refusal

    rescue_and_log(target: base) do
      twin = Appearances::IcedTwin.create!(base)
      redirect_to person_path(@person.slug, anchor: "look-#{twin.slug}"),
                  notice: "#{twin.descriptor} is #{base.descriptor}'s iced twin. Build its sheet on its page."
    end
  end

  def make_default_appearance
    appearance = @person.appearances.live.find_by(slug: params[:appearance_slug])
    return redirect_to(person_path(@person.slug), alert: "No such look.") unless appearance

    appearance.make_default!
    redirect_to person_path(@person.slug), notice: "#{appearance.descriptor} is now the default."
  end

  # Attach an image for one look. A character sheet is a one-subject artifact;
  # multi-person images are created by the content pipeline, not here.
  #
  # THE URL IS CHECKED BEFORE ANYTHING IS FILED. It becomes the look's newest
  # sheet: the operator's browser loads it on the cast card, and the chunk
  # hand-off gives it out as the swap reference. So it must be https on a public
  # host (Appearances::FetchableUrl.https?); a refusal writes no row.
  def attach_artifact
    appearance = @person.appearances.live.find_by(slug: params[:appearance_slug]) || @person.default_appearance
    return redirect_to(person_path(@person.slug), alert: "Create a look first.") unless appearance

    image_url = params[:image_url].to_s.strip
    unless Appearances::FetchableUrl.https?(image_url)
      return redirect_to(person_path(@person.slug), alert: Appearances::FetchableUrl::HTTPS_REFUSAL)
    end

    rescue_and_log(target: @person) do
      Artifact.transaction do
        artifact = Artifact.create!(kind: "character_sheet", image_url: image_url, source: "operator")
        artifact.subjects.create!(person_slug: @person.slug, appearance_slug: appearance.slug, ordinal: 1)
      end
      redirect_to person_path(@person.slug), notice: "Model image attached to #{appearance.descriptor}."
    end
  end

  # What this person does (Person::VOCATIONS): the boxes ticked, and which one
  # is primary. A refusal (a primary the person does not hold) is an answer,
  # not an ErrorLog.
  def update_vocations
    choice = params.fetch(:person, {}).permit(:primary_vocation, vocations: [])
    @person.assign_attributes(vocations: Array(choice[:vocations]).compact_blank, primary_vocation: choice[:primary_vocation])
    unless @person.valid?
      return redirect_to person_path(@person.slug), alert: "Vocations not saved: #{@person.errors.full_messages.to_sentence}."
    end

    rescue_and_log(target: @person) { @person.save! }
    redirect_to person_path(@person.slug), notice: vocations_notice
  end

  # The one way to change a person's slug: rename_slug rewrites every row that
  # names the old one in the same transaction. A refusal (blank, badly formed,
  # taken) renders the form again with the reason, as a 422.
  def edit_slug; end

  def update_slug
    old_slug = @person.slug
    rescue_and_log(target: @person) do
      unless @person.rename_slug(params.dig(:person, :slug))
        return render :edit_slug, status: :unprocessable_entity
      end
    end
    return redirect_to person_path(@person.slug), notice: "Slug unchanged." if @person.slug == old_slug

    redirect_to person_path(@person.slug), notice: "Renamed #{old_slug} to #{@person.slug}; every row that named it follows."
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

  # The cast card a "new look" link came from (/music_videos/<slug>#person-<n>),
  # so a saved look lands the operator back on it. Anything else is ignored.
  RECAST_RETURN = %r{\A/music_videos/[a-z0-9]+(?:-[a-z0-9]+)*(?:#person-\d+)?\z}
  helper_method :recast_return_path

  def recast_return_path
    params[:return_to].to_s[RECAST_RETURN]
  end

  # Each iced twin listed straight after its base look; a twin whose base is
  # gone keeps its own place at the end.
  def twins_beside_bases(looks)
    twins = looks.select(&:iced?).group_by(&:base_appearance_slug)
    looks.reject(&:iced?).flat_map { |look| [look, *twins.delete(look.slug)] } + twins.values.flatten
  end

  def vocations_notice
    return "#{@person.full_name} has no vocation." if @person.vocations.empty?

    others = @person.vocations - [@person.primary_vocation]
    "#{@person.full_name}: primary vocation #{@person.primary_vocation}#{", also #{others.to_sentence}" if others.any?}."
  end

  def appearance_params
    permitted = params.require(:appearance).permit(:descriptor, :team_slug, :colorway, :reference_url, :generation_notes,
                                                   :jersey_number)
    permitted.merge(jersey_number: Appearance.jersey_from(permitted[:jersey_number]))
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
      People::Merge.call!(keep: keep, source: merge_person)
      redirect_to people_path, notice: "Merged #{merge_person.full_name} into #{keep.full_name}."
    end
  rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique => e
    redirect_to merge_people_path, alert: "Merge failed: #{ConstraintViolationResponses.reason_for(e)}"
  rescue StandardError => e
    redirect_to merge_people_path, alert: "Merge failed: #{e.message}"
  end

  def duplicates
    @duplicate_groups = find_duplicate_groups
  end

  private

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
