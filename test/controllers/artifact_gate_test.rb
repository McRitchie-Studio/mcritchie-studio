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
end
