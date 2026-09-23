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
