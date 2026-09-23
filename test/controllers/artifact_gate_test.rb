require "test_helper"

# [integration] The inspection gate across its whole boundary: confirm the
# jersey, attach each artifact, approve — and the refusals that keep the gate
# meaningful.
class ArtifactGateTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    Artifact.delete_all
    Appearance.delete_all
    Content.where(workflow: "rapper_replace").destroy_all

    @burrow = Person.create!(first_name: "Joe", last_name: "Burrow", athlete: true)
    @chase  = Person.create!(first_name: "JaMarr", last_name: "Chase", athlete: true)
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white", colorway: "white")
    Appearance.create!(person_slug: @chase.slug,  descriptor: "Bengals white", colorway: "white")

    @content = Content.create!(
      title: "Burrow And Chase Torch Jaguars", workflow: "rapper_replace", stage: "idea",
      qb_player_slug: @burrow.slug, skill_player_slug: @chase.slug,
      game_facts: { "winner_slug" => "cincinnati-bengals",
                    "away_team_slug" => "cincinnati-bengals",
                    "home_team_slug" => "jacksonville-jaguars" }
    )
    log_in_as(@admin)
  end

  def slots = Content::ArtifactPlan.new(@content.reload).slots

  def attach(index, url = "/x.png")
    post attach_artifact_content_path(@content.slug),
         params: { slot_index: index, image_url: url }
  end

  def index_of(kind) = slots.index { |s| s.kind == kind }

  def attach_all = slots.each_index { |i| attach(i) }

  # --- component tier ------------------------------------------------------

  test "[component] the gate renders a slot per artifact with its decision" do
    get content_path(@content.slug)

    assert_response :success
    assert_match "Artifact Inspection", response.body
    assert_match "Both players", response.body
    assert_match "Quarterback", response.body
    assert_match "Skill player", response.body
    assert_equal 3, response.body.scan("GENERATE").length
  end

  test "[component] an unconfirmed colorway is labelled a guess" do
    get content_path(@content.slug)

    assert_match "GUESSED FROM HOME/AWAY", response.body
    assert_no_match(/CONFIRMED/, response.body)
  end

  # Each subject's own look is shown, because a mixed cast carries different
  # looks in one frame.
  test "[component] every subject's look is named on the slot" do
    get content_path(@content.slug)

    assert_match "Joe Burrow: Bengals white", response.body
    assert_match "JaMarr Chase: Bengals white", response.body
  end

  # THE SUBMIT LABEL IS A PROMISE ABOUT THE OPERATOR'S EXISTING ASSETS, and on a
  # re-skin slot it promised the opposite of what happens. `slot.artifact` on a
  # re-skin is the OTHER colorway, and its image_url IS present, so the label
  # read "Replace" on every slot while the attach keeps that artifact and adds a
  # second one beside it. That label was true while the attach retired its
  # source; it became false the moment the retire was made conditional. Telling
  # the operator an asset will be destroyed when it will be kept is the inverse
  # of the bug that change fixed, on the one screen whose job is trust about
  # assets.
  test "[component] a re-skin slot offers Attach, never Replace" do
    attach_all
    post set_colorway_content_path(@content.slug), params: { colorway: "black" }
    assert slots.all?(&:reskin?),
           "the control — these must be re-skins, or this test proves nothing. " \
           "Read #{slots.map(&:decision).inspect}"

    get content_path(@content.slug)

    assert_equal 3, response.body.scan(/value="Attach"/).length,
                 "every re-skin slot must offer Attach — the white artifact is kept, not replaced"
    assert_equal 0, response.body.scan(/value="Replace"/).length,
                 "a re-skin replaces nothing; Replace here tells the operator his asset is about to be destroyed"
  end

  # The other half of the predicate, and the reason it is not simply "always
  # Attach": a :reuse slot holds the SAME cast in the SAME look, the attach DOES
  # retire it (contents_controller: `slot.artifact&.retire! if slot.reuse?`), and
  # Replace is the honest word. A fix that flipped every label would break this.
  test "[component] a reuse slot still offers Replace" do
    attach_all
    assert slots.all?(&:reuse?),
           "the control — these must be reuses, or this test proves nothing. " \
           "Read #{slots.map(&:decision).inspect}"

    get content_path(@content.slug)

    assert_equal 3, response.body.scan(/value="Replace"/).length,
                 "a reuse attach retires the artifact it shows, so Replace is what happens"
    assert_equal 0, response.body.scan(/value="Attach"/).length
  end

  # An empty slot has no artifact to speak of either way.
  test "[component] a generate slot offers Attach" do
    get content_path(@content.slug)

    assert_equal 3, response.body.scan(/value="Attach"/).length
    assert_equal 0, response.body.scan(/value="Replace"/).length
  end

  test "[component] the gate disappears once approved" do
    @content.update!(artifacts_approved_at: Time.current)
    get content_path(@content.slug)

    assert_no_match(/Artifact Inspection/, response.body)
  end

  # --- integration tier ----------------------------------------------------

  test "confirming the jersey stops it reading as a guess" do
    post set_colorway_content_path(@content.slug), params: { colorway: "Black" }

    assert_equal "black", @content.reload.colorway
    get content_path(@content.slug)
    assert_match "CONFIRMED", response.body
  end

  # The ceiling this model exists to remove: a pair is two subject rows.
  test "attaching a pair files both people as subjects" do
    attach(index_of("pair"))

    artifact = Artifact.find_by(kind: "pair")
    assert_equal 2, artifact.subjects.count
    assert_equal [@burrow.slug, @chase.slug].sort, artifact.subjects.map(&:person_slug).sort
  end

  test "a character sheet files exactly one subject" do
    attach(index_of("character_sheet"))

    assert_equal 1, Artifact.find_by(kind: "character_sheet").subjects.count
  end

  # Supersede rather than delete: the old image stays as the record of what was
  # published before.
  test "replacing an image retires the old artifact rather than deleting it" do
    i = index_of("character_sheet")
    attach(i, "/one.png")
    attach(i, "/two.png")

    assert_equal 1, Artifact.live.where(kind: "character_sheet").count
    assert_equal 1, Artifact.where(kind: "character_sheet").where.not(retired_at: nil).count
  end

  test "approving stamps every artifact and the content" do
    attach_all

    post approve_artifacts_content_path(@content.slug)

    assert @content.reload.artifacts_approved?
    assert_equal 3, Artifact.approved.count
  end

  # The gate's whole job: refuse until a human could have looked at them all.
  test "approving is refused while a slot is empty" do
    attach(index_of("pair"))

    post approve_artifacts_content_path(@content.slug)

    assert_not @content.reload.artifacts_approved?
    assert_match(/needs an image/, flash[:alert])
  end

  # Changing the jersey re-decides every slot — colorway is part of an
  # artifact's identity, not a detail on it.
  test "changing the colorway turns reuses into re-skins" do
    attach_all
    post approve_artifacts_content_path(@content.slug)
    assert slots.all?(&:reuse?)

    post set_colorway_content_path(@content.slug), params: { colorway: "black" }

    assert slots.all?(&:reskin?),
           "artifacts approved in white must read as re-skins once the jersey changes"
  end

  # --- the repeat case: the same pair, a different jersey, then back -------
  #
  # This is the case the screen was built for. A face does not change week to
  # week; only the jersey does. So filing the black recolor must not cost the
  # white artifact — and the test that proves it has to run the WHOLE cycle,
  # because the defect was invisible after two attaches and only showed on the
  # third.

  test "attaching a re-skin leaves the other colorway live" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")
    Appearance.create!(person_slug: @chase.slug,  descriptor: "Bengals black", colorway: "black")

    attach_all
    assert_equal 3, Artifact.live.count, "the white set is on file"

    post set_colorway_content_path(@content.slug), params: { colorway: "black" }
    assert slots.all?(&:reskin?), "the control — these must be re-skins, or this proves nothing"

    attach_all

    assert_equal 6, Artifact.live.count,
                 "filing the black recolor retired the white artifacts it was re-skinned FROM — " \
                 "the library can then hold only one live artifact per cast, and the reuse this " \
                 "screen exists for is impossible"
    assert_equal 0, Artifact.where.not(retired_at: nil).count,
                 "a re-skin supersedes nothing; nothing should have been retired"
  end

  # The third pass is the one that bites: white, black, then white again. With
  # the unconditional retire the white artifacts are gone by now, so the gate
  # bills a RECOLOR for a jersey it already had on file — it reads `:reskin`
  # off the black artifact instead of `:reuse` off the white one. It does not
  # ask for a fresh generation: every attach files a replacement in the same
  # transaction, so the cast never drops to zero live artifacts and `:generate`
  # is unreachable here. Measured by reinstating the unconditional retire —
  # this pass then prints [:reskin, :reskin, :reskin].
  test "a jersey the pair has worn before still reads reuse on the way back" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")
    Appearance.create!(person_slug: @chase.slug,  descriptor: "Bengals black", colorway: "black")

    attach_all                                                              # white
    post set_colorway_content_path(@content.slug), params: { colorway: "black" }
    attach_all                                                              # black
    post set_colorway_content_path(@content.slug), params: { colorway: "white" }

    assert slots.all?(&:reuse?),
           "back in white, every slot must read REUSE — the artifacts are still on file. " \
           "Read #{slots.map(&:decision).inspect}"
  end

  # --- the colliding empty look -------------------------------------------
  #
  # Zero appearances is every person's state until their first look is filed, so
  # this is the common path on a fresh person, not a corner. The gate card still
  # renders the real image — a human looking at the screen sees the picture, which
  # is the gate's whole job — but the DECISION LABEL said "Reuse" over an artifact
  # whose jersey nobody had recorded, and the label is what an operator trusts
  # when skimming.

  test "[integration] a named colorway does not reuse an artifact whose look was never recorded" do
    bare = Person.create!(first_name: "Bare", last_name: "Look", athlete: true)
    @content.update!(qb_player_slug: bare.slug, skill_player_slug: nil, colorway: "black")

    artifact = Artifact.create!(kind: "character_sheet", image_url: "/x.png", approved_at: Time.current)
    artifact.subjects.create!(person_slug: bare.slug, appearance_slug: nil, ordinal: 1)

    sheet = slots.find { |s| s.kind == "character_sheet" }

    assert_not sheet.reuse?,
               "the request named black and this person has no black look; an artifact whose look " \
               "was never recorded cannot be known to satisfy it. Read #{sheet.decision.inspect}"
    assert sheet.reskin?, "the face work is done and only the wardrobe is unknown — that is a recolor"
    assert_equal "have an artifact for this cast with no look recorded — recolor for this game",
                 sheet.detail,
                 "the re-skin sentence used to lose its object here: every descriptor is nil, so " \
                 "the list compacted to empty and the card read 'have  — recolor for this game'"
  end

  test "[integration] the gate page stops claiming an approved artifact is on file" do
    bare = Person.create!(first_name: "Bare", last_name: "Look", athlete: true)
    @content.update!(qb_player_slug: bare.slug, skill_player_slug: nil, colorway: "black")
    artifact = Artifact.create!(kind: "character_sheet", image_url: "/x.png", approved_at: Time.current)
    artifact.subjects.create!(person_slug: bare.slug, appearance_slug: nil, ordinal: 1)

    get content_path(@content.slug)

    assert_response :success
    assert_no_match(/approved artifact on file/, response.body,
                    "that sentence is the reuse detail, and reuse is exactly what this must not be")
  end

  # AND THE LEGITIMATE EMPTY MATCH SURVIVES. With no colorway to resolve — no
  # confirmation and no game facts to guess from — there is nothing for the
  # artifact to contradict, and refusing here would make the gate offer to
  # regenerate an image it is already holding.
  test "[integration] with no colorway at all a lookless artifact is still reused" do
    bare = Person.create!(first_name: "Bare", last_name: "Look", athlete: true)
    @content.update!(qb_player_slug: bare.slug, skill_player_slug: nil, colorway: nil, game_facts: {})
    artifact = Artifact.create!(kind: "character_sheet", image_url: "/x.png", approved_at: Time.current)
    artifact.subjects.create!(person_slug: bare.slug, appearance_slug: nil, ordinal: 1)

    sheet = slots.find { |s| s.kind == "character_sheet" }

    assert_nil Content::ArtifactPlan.new(@content.reload).colorway,
               "the control — with no confirmation and no game facts there is no colorway to resolve"
    assert sheet.reuse?, "nothing was asked for, so nothing is contradicted. Read #{sheet.decision.inspect}"
  end

  # The supersede itself must still happen, or the fix above has simply turned
  # the retire off. Same cast, same look, a new image: that one IS a replacement.
  test "a reuse attach still retires the artifact it replaces" do
    i = index_of("pair")
    attach(i, "/first.png")
    assert slots[i].reuse?, "the control — the second attach must be deciding REUSE"

    attach(i, "/second.png")

    assert_equal 1, Artifact.live.where(kind: "pair").count
    assert_equal 1, Artifact.where(kind: "pair").where.not(retired_at: nil).count
  end

  # --- the look an attach files -------------------------------------------
  #
  # THE WRITE, not a reader. The attach filed `appearance_slug: nil` whenever
  # the content named a colorway the person had no look in, while every read
  # resolves nil to the person's DEFAULT — so the row went in under
  # `person@<default>` and the lookup asked for `person@`. Three consumer
  # censuses could not see it, because every consumer was correct.
  #
  # It is reachable on the ordinary path, not on unusual operator input: this
  # cast's only filed look is Bengals white, and a HOME win guesses "primary",
  # which is half of all games.

  # Put the Bengals at home so `guessed_colorway` answers "primary" — a colorway
  # neither player has a look in.
  def home_win!
    @content.update!(game_facts: { "winner_slug" => "cincinnati-bengals",
                                   "away_team_slug" => "jacksonville-jaguars",
                                   "home_team_slug" => "cincinnati-bengals" })
  end

  def assert_unfiled_colorway
    assert_equal "primary", Content::ArtifactPlan.new(@content.reload).colorway,
                 "the control — the guess must be primary, or this test proves nothing"
    assert_equal [], Appearance.live.where(colorway: "primary").pluck(:person_slug),
                 "the control — nobody may have a primary look yet, or this test proves nothing"
  end

  test "an attach for an unfiled colorway records the look it was uploaded for" do
    home_win!
    assert_unfiled_colorway

    attach(index_of("pair"))

    filed = Artifact.find_by(kind: "pair").subjects.map(&:appearance_slug)
    assert_equal 2, filed.compact.length, "both subjects must carry a look, not a null"
    assert_equal ["primary", "primary"],
                 Appearance.where(slug: filed).pluck(:colorway),
                 "the look filed must be the colorway the image was uploaded FOR"
  end

  # ACCEPTANCE 2: a filed artifact is found by its own lookup. Before the write
  # recorded the look this read :reskin forever — the slot that created the
  # artifact could not see it.
  test "the slot finds the artifact it just created" do
    home_win!
    assert_unfiled_colorway

    attach_all

    assert_equal [:reuse, :reuse, :reuse], slots.map(&:decision),
                 "every slot must find its own artifact; :reskin means the lookup missed it"
  end

  # THE OPERATOR-VISIBLE FAILURE. A miss on the exact match leaves the slot on
  # :reskin, so the attach never retires what it replaces: the library doubles
  # and the page keeps rendering the FIRST image while the operator pastes new
  # ones. Measured before the fix: 6 live artifacts and /first.png still on the
  # page.
  test "replacing an image on an unfiled colorway actually replaces it" do
    home_win!
    assert_unfiled_colorway
    attach_all
    assert_equal 3, Artifact.live.count, "the control — one live artifact per slot before the replace"

    slots.each_index { |i| attach(i, "/second-#{i}.png") }

    assert_equal 3, Artifact.live.count,
                 "the replacement must supersede, not pile up beside what it replaces"
    get content_path(@content.slug)
    assert_match "/second-0.png", response.body,
                 "the image the operator just attached must be the one on the page"
    assert_no_match(/\/x\.png/, response.body,
                    "the superseded image must be gone from the page")
  end

  # The page told the operator "no look" for a person whose look it had just
  # filed — on the one screen whose job is trust about assets.
  test "[component] the slot names the look rather than claiming there is none" do
    home_win!
    assert_unfiled_colorway
    attach_all

    get content_path(@content.slug)

    assert_no_match(/no look/, response.body)
    assert_match "Joe Burrow: Primary", response.body
  end

  # THE LATENT HALF, and the reason nil is not merely cosmetic. A null row is
  # findable only while the person has NO default. Giving them their first look
  # later re-points every read and strands every artifact already on file for
  # them — silently, with no error and nothing to grep for.
  test "a look created later does not strand the artifacts already filed" do
    Appearance.delete_all
    # `Appearance.delete_all` leaves the person pointing at the row it deleted,
    # and `become_default_if_first` only fires on a BLANK pointer — so without
    # this the new look below never becomes the default, the read never
    # re-points, and the test passes on the broken tree for the wrong reason.
    Person.where(slug: [@burrow.slug, @chase.slug]).update_all(default_appearance_slug: nil)
    home_win!
    assert_nil Person.find_by(slug: @burrow.slug).default_appearance_slug,
               "the control — the cast must start with no looks and no default pointer"

    attach_all
    assert_equal [:reuse, :reuse, :reuse], slots.map(&:decision), "the control — filed and findable"

    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white", colorway: "white")
    Appearance.create!(person_slug: @chase.slug,  descriptor: "Bengals white", colorway: "white")
    assert Person.find_by(slug: @burrow.slug).default_appearance,
           "the control — the new look must have become the default, or the read never re-points"

    assert_equal [:reuse, :reuse, :reuse], slots.map(&:decision),
                 "a new look must not strand artifacts already filed for this cast"
  end

  # --- the wiring blockers a review found ---------------------------------

  # The gate was unreachable in production: nothing wrote the cast, so
  # ArtifactPlan#cast was always empty, slots was always [], and approve always
  # refused — while the workflow sat in the operator's dropdown.
  test "an operator can set the cast through the edit form" do
    blank = Content.create!(title: "No cast yet", workflow: "rapper_replace", stage: "idea")

    patch content_path(blank.slug), params: { content: {
      qb_player_slug: @burrow.slug, skill_player_slug: @chase.slug, colorway: "white"
    } }

    blank.reload
    assert_equal @burrow.slug, blank.qb_player_slug
    assert_equal @chase.slug, blank.skill_player_slug
    assert_equal 3, Content::ArtifactPlan.new(blank).slots.length,
                 "a content with a cast must produce slots — otherwise the gate can never open"
  end

  # Adding :show drew GET /people/:slug, which swallowed the literal
  # /people/search and 404'd the person picker in news/edit and people/merge.
  test "the people search route is not shadowed by the person page" do
    assert_equal({ controller: "people", action: "search" },
                 Rails.application.routes.recognize_path("/people/search"))
    assert_equal({ controller: "people", action: "show", slug: "joe-burrow" },
                 Rails.application.routes.recognize_path("/people/joe-burrow"))
  end

  test "the person search endpoint answers" do
    get search_people_path, params: { q: "Burrow" }

    assert_response :success
    assert_includes JSON.parse(response.body).map { |p| p["slug"] }, @burrow.slug
  end
end
