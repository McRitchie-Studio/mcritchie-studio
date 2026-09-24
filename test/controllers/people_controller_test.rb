require "test_helper"

class PeopleControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
  end

  test "index renders without login" do
    get people_path
    assert_response :success
  end

  test "merge page requires authentication" do
    get merge_people_path
    assert_response :redirect
  end

  test "merge page renders when logged in" do
    log_in_as(@admin)
    get merge_people_path
    assert_response :success
  end

  test "duplicates page requires authentication" do
    get duplicates_people_path
    assert_response :redirect
  end

  test "duplicates page renders when logged in" do
    log_in_as(@admin)
    get duplicates_people_path
    assert_response :success
  end

  test "merge_execute moves contracts and deletes source" do
    log_in_as(@admin)

    # Create two people — keep and merge (unique names to avoid fixture collision)
    keep = Person.create!(first_name: "Terrence", last_name: "Ferguson", athlete: true)
    source = Person.create!(first_name: "Terrance", last_name: "Ferguson", athlete: true)

    # Give source a contract
    team = teams(:argentina) # any team
    Contract.create!(person_slug: source.slug, team_slug: team.slug, position: "TE", contract_type: "active")

    assert_difference "Person.count", -1 do
      post merge_people_path, params: { keep_slug: keep.slug, merge_slug: source.slug }
    end

    assert_redirected_to people_path
    assert_nil Person.find_by(slug: source.slug)

    # Contract moved to keep
    contract = Contract.find_by(person_slug: keep.slug, team_slug: team.slug)
    assert_not_nil contract

    # Alias added
    keep.reload
    assert_includes keep.aliases, "Terrance Ferguson"
  end

  test "merge_execute prevents merging into self" do
    log_in_as(@admin)
    person = people(:messi)
    post merge_people_path, params: { keep_slug: person.slug, merge_slug: person.slug }
    assert_redirected_to merge_people_path
    follow_redirect!
    assert_response :success
  end

  test "merge_execute requires both people" do
    log_in_as(@admin)
    post merge_people_path, params: { keep_slug: "nonexistent", merge_slug: "also-nonexistent" }
    assert_redirected_to merge_people_path
  end

  test "merge_execute re-parents athlete when keep has none" do
    log_in_as(@admin)

    keep = Person.create!(first_name: "Jaxon", last_name: "Testmerge", athlete: true)
    source = Person.create!(first_name: "Jackson", last_name: "Testmerge", athlete: true)
    source_athlete = Athlete.create!(person_slug: source.slug, sport: "football", position: "QB")

    post merge_people_path, params: { keep_slug: keep.slug, merge_slug: source.slug }

    assert_nil Person.find_by(slug: source.slug)
    source_athlete.reload
    assert_equal keep.slug, source_athlete.person_slug
  end

  # --- merging two people merges their PICTURES too ------------------------
  #
  # `perform_merge!` relocates contracts, roster spots, coaches, athlete
  # profiles, grades, stats and aliases, then destroys the source. It used to
  # move neither the source's LOOKS nor their ARTIFACT CAST, so
  # `Person has_many :appearances, dependent: :destroy` and
  # `has_many :artifact_subjects, dependent: :destroy` deleted both.
  #
  # Measured on the unfixed tree: a pair artifact went from three subjects to
  # one across two artifacts, a character sheet was left with an empty cast
  # label, and the pair's reuse key collapsed to a ONE-PERSON key — so it would
  # match solo lookups it should never match and never again match the pair it
  # actually depicts.

  def merge!(keep, source)
    post merge_people_path, params: { keep_slug: keep.slug, merge_slug: source.slug }
  end

  test "merge moves the source's looks to the survivor" do
    log_in_as(@admin)
    keep   = Person.create!(first_name: "Marcus", last_name: "Lookmerge")
    source = Person.create!(first_name: "Markus", last_name: "Lookmerge")
    look   = Appearance.create!(person_slug: source.slug, descriptor: "Navy suit")

    assert_equal 1, source.appearances.live.count, "the control — the source has a look to lose"

    merge!(keep, source)

    assert_nil Person.find_by(slug: source.slug)
    assert_equal keep.slug, look.reload.person_slug
    assert_equal ["Navy suit"], keep.reload.appearances.live.pluck(:descriptor)
  end

  # THE SEAM BETWEEN THE TWO HALVES OF THIS WORK. Relocation is an UPDATE and
  # `become_default_if_first` is an after_CREATE, so moving a look onto the
  # survivor stamps nothing. Measured before the fix: survivor with one live
  # look and a nil default — the same broken state a destroyed default leaves.
  test "a survivor who inherits their first look resolves a default" do
    log_in_as(@admin)
    keep   = Person.create!(first_name: "Dominic", last_name: "Defmerge")
    source = Person.create!(first_name: "Dominik", last_name: "Defmerge")
    Appearance.create!(person_slug: source.slug, descriptor: "Navy suit")

    assert_nil keep.reload.default_appearance_slug, "the control — the survivor starts with no looks at all"

    merge!(keep, source)

    keep.reload
    assert_equal 1, keep.appearances.live.count
    assert_not_nil keep.default_appearance,
                   "live looks and no resolvable default is exactly the state this work exists to remove"
  end

  test "merge moves artifact subjects and keeps the pair's reuse key whole" do
    log_in_as(@admin)
    keep   = Person.create!(first_name: "Gregory", last_name: "Castmerge")
    source = Person.create!(first_name: "Gregorio", last_name: "Castmerge")
    other  = Person.create!(first_name: "Bystander", last_name: "Castmerge")
    sl = Appearance.create!(person_slug: source.slug, descriptor: "Navy suit")
    ol = Appearance.create!(person_slug: other.slug,  descriptor: "Grey suit")

    pair = Artifact.create!(kind: "pair", image_url: "/p.png", approved_at: Time.current)
    pair.subjects.create!(person_slug: other.slug,  appearance_slug: ol.slug, ordinal: 1)
    pair.subjects.create!(person_slug: source.slug, appearance_slug: sl.slug, ordinal: 2)

    assert_equal 2, pair.subjects.count, "the control — a two-person cast before the merge"

    merge!(keep, source)

    pair.reload
    assert_equal 2, pair.subjects.reload.count, "the cast must survive the merge intact"
    assert_equal [keep.slug, other.slug].sort, pair.subjects.map(&:person_slug).sort
    assert_includes pair.subject_key, "#{keep.slug}@#{sl.slug}"
    assert Artifact.matching([[keep.slug, sl.slug], [other.slug, ol.slug]], kind: "pair"),
           "the survivor's own cast must still find the image"
  end

  test "merge leaves no artifact depicting nobody" do
    log_in_as(@admin)
    keep   = Person.create!(first_name: "Nathaniel", last_name: "Sheetmerge")
    source = Person.create!(first_name: "Nathanael", last_name: "Sheetmerge")
    sl = Appearance.create!(person_slug: source.slug, descriptor: "Navy suit")
    sheet = Artifact.create!(kind: "character_sheet", image_url: "/s.png", approved_at: Time.current)
    sheet.subjects.create!(person_slug: source.slug, appearance_slug: sl.slug, ordinal: 1)

    assert_equal "Nathanael Sheetmerge", sheet.cast_label, "the control"

    merge!(keep, source)

    sheet.reload
    assert_equal 1, sheet.subjects.reload.count
    assert_equal "Nathaniel Sheetmerge", sheet.cast_label
    assert_not_equal "", sheet.subject_key
  end

  # THE COLLIDING-DESCRIPTOR FORK, settled by measurement rather than argument.
  # `index_appearances_live_per_person` is unique on (person_slug, descriptor)
  # among live looks, so the source's look cannot simply move — a naive
  # relocation raises RecordNotUnique and kills the whole merge.
  #
  # Of the three ways out, only re-pointing the subjects at the survivor's own
  # look leaves the image findable: retiring-and-moving it, or moving it under a
  # suffixed name, both key the artifact to a look no lookup will ever ask for
  # again, so an approved image of the right person in the right outfit goes
  # permanently invisible to `Artifact.matching`.
  test "a colliding descriptor re-points the cast at the survivor's own look" do
    log_in_as(@admin)
    keep   = Person.create!(first_name: "Frederick", last_name: "Clashmerge")
    source = Person.create!(first_name: "Frederik", last_name: "Clashmerge")
    twin = Appearance.create!(person_slug: keep.slug,   descriptor: "Navy suit", colorway: "navy")
    sl   = Appearance.create!(person_slug: source.slug, descriptor: "Navy suit", colorway: "navy")

    sheet = Artifact.create!(kind: "character_sheet", image_url: "/c.png", approved_at: Time.current)
    sheet.subjects.create!(person_slug: source.slug, appearance_slug: sl.slug, ordinal: 1)
    assert_equal sl.slug, sheet.subjects.first.appearance_slug, "the control"

    assert_nothing_raised { merge!(keep, source) }

    assert_nil Person.find_by(slug: source.slug), "the merge must actually complete"
    keep.reload
    assert_equal ["Navy suit"], keep.appearances.live.pluck(:descriptor),
                 "one look per descriptor — the twin absorbs it"
    sheet.reload
    assert_equal twin.slug, sheet.subjects.reload.first.appearance_slug
    assert Artifact.matching([[keep.slug, twin.slug]], kind: "character_sheet"),
           "the survivor's own look must find the image it inherited"
  end

  # An image casting BOTH people depicts, after the merge, one person twice —
  # a cast that never existed. `index_artifact_subjects_on_artifact_slug_and_person_slug`
  # forbids the duplicate row, and leaving it live with one subject is worse
  # than retiring it: the row stays APPROVED while describing a cast its own
  # image does not show.
  #
  # The `matching` assertion below calls the lookup BY HAND. No production path
  # builds it: `Content::ArtifactPlan#pair_slot` returns nil for a cast under
  # two, and it is the only caller naming `kind: "pair"`. The assertion still
  # discriminates — skip the retire and it finds the halved row — so it pins the
  # retire rather than a reachable false match.
  test "an artifact casting both people is retired rather than quietly halved" do
    log_in_as(@admin)
    keep   = Person.create!(first_name: "Sebastian", last_name: "Bothmerge")
    source = Person.create!(first_name: "Sebastien", last_name: "Bothmerge")
    kl = Appearance.create!(person_slug: keep.slug,   descriptor: "Home")
    sl = Appearance.create!(person_slug: source.slug, descriptor: "Away")

    pair = Artifact.create!(kind: "pair", image_url: "/b.png", approved_at: Time.current)
    pair.subjects.create!(person_slug: keep.slug,   appearance_slug: kl.slug, ordinal: 1)
    pair.subjects.create!(person_slug: source.slug, appearance_slug: sl.slug, ordinal: 2)
    assert_not pair.retired?, "the control"

    assert_nothing_raised { merge!(keep, source) }

    assert_nil Person.find_by(slug: source.slug), "the merge must actually complete"
    pair.reload
    assert pair.retired?, "a pair of one person is a cast that never existed"
    assert_nil Artifact.matching([[keep.slug, kl.slug]], kind: "pair"),
               "and it must not be reusable as a one-person pair"
  end
end
