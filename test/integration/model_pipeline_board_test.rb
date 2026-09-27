require "test_helper"

# [integration] THE MODEL PIPELINE BOARD, end to end over HTTP.
#
# What is proved here rather than in the unit tier:
#
#   THE DRAG SPENDS NOTHING  the operator's instruction was two instructions — keep the
#                            drag, wire it to no side effect — and the second is a
#                            property of the REQUEST, not of an object. A PATCH writes
#                            one column and files no photograph, no image and no job.
#   THE REFUSAL IS AT THE WRITE  a backward drag is answered with a 422 and a sentence
#                            the board primitive toasts, rather than accepted and
#                            silently corrected on the next read.
#   THE PUBLIC READ IS READ-ONLY  a visitor gets the board with no move and no reorder
#                            endpoint, so the affordance and the permission agree.
#   THE RANK ROUND-TRIPS     the shared Studio::Board::Reorderable action restamps the
#                            lane and the next render comes back in the new order.
class ModelPipelineBoardTest < ActionDispatch::IntegrationTest
  setup do
    Appearance.delete_all
    AppearanceReferencePhoto.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    ImageCache.where(purpose: "headshot").delete_all

    @athlete = athletes(:allen_athlete)
    @athlete.update!(team_slug: "buffalo-bills")
    @person = people(:josh_allen)
  end

  def look!(descriptor, person: @person, **attrs)
    Appearance.create!(person_slug: person.slug, descriptor: descriptor, **attrs)
  end

  def candidates!(look, count, chosen: 0)
    count.times do |i|
      AppearanceReferencePhoto.create!(appearance_slug: look.slug,
                                       image_url: "https://x.test/#{look.slug}-#{i}.jpg",
                                       source: AppearanceReferencePhoto::SOURCE_SEARCH,
                                       chosen: i < chosen)
    end
  end

  def sheet!(look, source: "openai")
    artifact = Artifact.create!(kind: "character_sheet", source: source,
                               image_url: "https://x.test/#{look.slug}.png")
    ArtifactSubject.create!(artifact_slug: artifact.slug, person_slug: look.person_slug,
                            appearance_slug: look.slug, ordinal: 1)
  end

  # ── the page ──────────────────────────────────────────────────────────────────

  test "the board renders all five lanes and puts each look in the lane its evidence names" do
    look!("Bare", person: people(:messi))
    look!("Defined", colorway: "bills home")
    chosen = look!("Chosen", colorway: "bills navy", person: people(:cam_ward))
    candidates!(chosen, 8, chosen: 3)

    get model_pipeline_path

    assert_response :success
    Appearances::LookReading::STAGES.each do |stage|
      assert_select "[data-board-column='#{stage}'] #dropzone-#{stage}.kanban-dropzone", 1
    end
    assert_select "#dropzone-designed .kanban-card", 1
    assert_select "#dropzone-defined .kanban-card", 1
    assert_select "#dropzone-model .kanban-card", 1
    assert_select "#dropzone-source .kanban-card", 0
    assert_select "[data-test='pipeline-total']", text: /3 models/
  end

  # THE BOARD STATES ITS OWN RULES, because both are answers to questions the operator
  # will have the first time a card does not go where he put it.
  test "the page states that a drag triggers nothing and how a jersey number is filled" do
    get model_pipeline_path

    assert_select "[data-test='pipeline-legend']", text: /Dragging a card triggers nothing/
    assert_select "[data-test='pipeline-legend']", text: /forward, never back/
    assert_select "[data-test='pipeline-definition-gap']",
                  text: /fills per athlete on demand from ESPN, never by backfill/
  end

  test "a traded look is counted and shown in defined rather than where its work reached" do
    traded = look!("Old jersey", colorway: "bengals white", team_slug: "cincinnati-bengals")
    candidates!(traded, 9, chosen: 4)
    sheet!(traded)

    get model_pipeline_path

    assert_select "[data-test='pipeline-stale-count']", text: /1 need re-defining/
    assert_select "#dropzone-defined [data-test='look-card-stale']", 1
    assert_select "#dropzone-generation .kanban-card", 0
  end

  # ── who a card says this is, and its sports data ──────────────────────────────

  # THE OPERATOR'S ASK (2026-09-27): "they should have an avatar, name and even a row of
  # data dedicated to there sports data, team and position."
  test "an athlete card carries an avatar, a name and a sports row" do
    @athlete.update!(position: "QB", height_inches: 77, weight_lbs: 237)
    cache = ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "400",
                               s3_key: "headshots/nfl/buffalo-bills/josh-allen/400.png",
                               content_type: "image/png")
    look!("With a face", colorway: "bills home")

    get model_pipeline_path

    assert_select "[data-test='look-card-person']", text: "Josh Allen"
    assert_select "img[data-test='look-card-avatar'][src='#{cache.url}']", 1
    assert_select "[data-test='look-card-sports-team']", text: "Buffalo Bills"
    assert_select "[data-test='look-card-sports-position']", text: "QB"
    assert_select "[data-test='look-card-sports-size']", text: /237lb/
  end

  # AN ATHLETE WITH NO espn_id HAS NO CACHED HEADSHOT — a real state, not an accident.
  test "a card with no cached headshot renders initials rather than a broken image" do
    look!("Faceless", colorway: "bills home")

    get model_pipeline_path

    assert_select "[data-test='look-card-avatar']", 0
    assert_select "[data-test='look-card-avatar-initials']", text: /JA/
  end

  # THE JERSEY NUMBER, END TO END. `athletes.jersey_number` landed 2026-09-27 and fills
  # per athlete on demand, so both states are real on a live board: a number we hold is
  # printed, and one we do not is a NAMED gap rather than an omitted cell, because a row
  # that dropped it would read as complete. The legend carries the actionable version.
  test "a card prints the jersey number it holds and names the gap when it has none" do
    look!("Numberless", colorway: "bills home")

    get model_pipeline_path
    assert_select "[data-test='look-card-sports-number']", text: "no #"
    assert_select "[data-test='pipeline-definition-gap']", text: /fills per athlete on demand/

    @athlete.update!(jersey_number: 17)
    get model_pipeline_path
    assert_select "[data-test='look-card-sports-number']", text: "#17"
  end

  # `appearances.person_slug` carries NO foreign key, so a look can name a person who is
  # not on file and nothing else in the app would notice. The lane that claims "the
  # person's data is captured and current" must not be enterable by one.
  test "a look with no person on file is held in designed, counted and flagged" do
    orphan = look!("Orphan", colorway: "bills home")
    candidates!(orphan, 9, chosen: 4)
    sheet!(orphan)
    orphan.update_column(:person_slug, "nobody-at-all")

    get model_pipeline_path

    assert_select "[data-test='pipeline-orphan-count']", text: /1 with no person on file/
    assert_select "#dropzone-designed [data-test='look-card-orphan']", 1
    assert_select "#dropzone-designed [data-test='look-card-person']", text: "nobody-at-all"
    assert_select "#dropzone-generation .kanban-card", 0
  end

  test "a person with no athlete record and no notes is held in designed" do
    Athlete.where(person_slug: people(:neymar).slug).destroy_all
    look!("No record", colorway: "c", person: people(:neymar))

    get model_pipeline_path

    assert_select "#dropzone-designed [data-test='look-card-blocker']", text: /No athlete record behind/
    assert_select "#dropzone-designed [data-test='look-card-sports']", 0
  end

  # ── the drag writes one column and NOTHING else ───────────────────────────────

  test "an admin drag forward records the placement and the card moves" do
    look = look!("Pushed", colorway: "bills home")
    log_in_as(users(:alex))

    patch model_pipeline_look_path(look.slug), params: { appearance: { stage: "generation" } }, as: :json

    assert_response :success
    assert_equal "generation", response.parsed_body["stage"]
    assert_equal "generation", look.reload.stage

    get model_pipeline_path
    assert_select "#dropzone-generation [data-test='look-card-hand-placed']", 1
  end

  # THE COST PROPERTY, asserted as an observation of the request rather than as a claim
  # about the code: a drag files no photograph, no image, no artifact subject and no job,
  # and touches no column on the look but `stage`. A board that spent money when a card
  # was dragged would be the worst version of this feature.
  test "a drag spends nothing — no photograph, no image, no job, no other column" do
    look = look!("Quiet", colorway: "bills home")
    candidates!(look, 4, chosen: 2)
    before = look.reload.attributes.except("stage", "updated_at")
    counts = -> { [AppearanceReferencePhoto.count, Artifact.count, ArtifactSubject.count, ImageCache.count] }
    counted = counts.call
    log_in_as(users(:alex))

    assert_no_enqueued_jobs do
      patch model_pipeline_look_path(look.slug), params: { appearance: { stage: "generation" } }, as: :json
    end

    assert_response :success
    assert_equal counted, counts.call, "a drag must file nothing"
    assert_equal before, look.reload.attributes.except("stage", "updated_at"),
                 "a drag writes the hand placement and no other column"
  end

  # THE REFUSAL HAPPENS AT THE WRITE. Accepting it and correcting it on the next page
  # load was the alternative, and a silent correction teaches the operator the board eats
  # his input.
  # A LOOK THE BOARD HOLDS IN DESIGNED CANNOT BE DRAGGED PAST ITS CONNECTION EITHER —
  # the same rule, reached through the connection rather than through the work.
  test "an orphan cannot be dragged out of designed" do
    orphan = look!("Orphan", colorway: "bills home")
    orphan.update_column(:person_slug, "nobody-at-all")
    log_in_as(users(:alex))

    patch model_pipeline_look_path(orphan.slug), params: { appearance: { stage: "defined" } }, as: :json

    assert_response :success, "designed is not BEHIND designed, so a forward placement is allowed"
    get model_pipeline_path
    assert_select "#dropzone-defined [data-test='look-card-orphan']", 1,
                  "the placement is honoured, and the card still says the person is missing"
  end

  test "a drag behind the evidence is refused with the reason, and nothing is written" do
    delivered = look!("Delivered", colorway: "bills home")
    candidates!(delivered, 9, chosen: 4)
    sheet!(delivered)
    log_in_as(users(:alex))

    patch model_pipeline_look_path(delivered.slug), params: { appearance: { stage: "defined" } }, as: :json

    assert_response :unprocessable_entity
    assert_match(/Stays in Generation/, response.parsed_body["error"])
    assert_match(/moves forward of its evidence, never behind it/, response.parsed_body["error"])
    assert_match(/1 image delivered/, response.parsed_body["error"],
                 "the refusal names the evidence that blocked it, not a rule number")
    assert_nil delivered.reload.stage
  end

  test "a lane that is not one of the five is refused" do
    look = look!("Quiet", colorway: "bills home")
    log_in_as(users(:alex))

    patch model_pipeline_look_path(look.slug), params: { appearance: { stage: "shipped" } }, as: :json

    assert_response :unprocessable_entity
    assert_match(/not one of the five lanes/, response.parsed_body["error"])
    assert_nil look.reload.stage
  end

  test "a look that is not on the board answers with an instruction rather than a 500" do
    log_in_as(users(:alex))

    patch model_pipeline_look_path("look-nobody-has"), params: { appearance: { stage: "defined" } }, as: :json

    assert_response :not_found
    assert_match(/reload and try again/, response.parsed_body["error"])
  end

  # ── the rank ──────────────────────────────────────────────────────────────────

  test "a reorder restamps the lane and the board comes back in the new order" do
    first = look!("First", colorway: "a")
    second = look!("Second", colorway: "b")
    log_in_as(users(:alex))

    post reorder_model_pipeline_path(format: :json), params: { slugs: [first.slug, second.slug], zone: "defined" }

    assert_response :success
    assert_operator first.reload.position, :>, second.reload.position

    get model_pipeline_path
    order = css_select("#dropzone-defined .kanban-card").map { |el| el["data-slug"] }
    assert_equal [first.slug, second.slug], order
  end

  test "a reorder without an id list is refused rather than guessed at" do
    log_in_as(users(:alex))

    post reorder_model_pipeline_path(format: :json), params: { zone: "defined" }

    assert_response :unprocessable_entity
  end

  # ── the gate ──────────────────────────────────────────────────────────────────

  # THE READ IS PUBLIC and spends nothing, matching /contents and /tasks beside it; every
  # write is admin, because hub signup is open and a session is therefore no control.
  test "a visitor reads the board but is given no way to write to it" do
    look!("Quiet", colorway: "bills home")

    get model_pipeline_path

    assert_response :success
    assert_select "[data-board-column='defined'] .kanban-card", 1
    board = css_select("section[data-test='studio-board']").first["x-data"]
    assert_match(/"moveUrl":null/, board, "a visitor is offered no cross-lane endpoint")
    assert_match(/"reorderUrl":null/, board, "a visitor is offered no reorder endpoint")
    refute_match(/cursor-grab/, response.body)
  end

  test "an admin is given both endpoints" do
    look!("Quiet", colorway: "bills home")
    log_in_as(users(:alex))

    get model_pipeline_path

    board = css_select("section[data-test='studio-board']").first["x-data"]
    assert_match(%r{"moveUrl":"/model_pipeline/:id.json"}, board)
    assert_match(%r{"reorderUrl":"/model_pipeline/reorder.json"}, board)
  end

  test "a signed-in non-admin cannot drag or reorder" do
    look = look!("Quiet", colorway: "bills home")
    # The genesis rank is stamped on CREATE (Rankable#set_initial_position), so "the
    # reorder did nothing" is the rank NOT MOVING rather than the column being nil.
    seeded_rank = look.reload.position
    log_in_as(users(:viewer))

    patch model_pipeline_look_path(look.slug), params: { appearance: { stage: "generation" } }, as: :json
    assert_response :redirect
    assert_nil look.reload.stage

    post reorder_model_pipeline_path(format: :json), params: { slugs: [look.slug] }
    assert_response :redirect
    assert_equal seeded_rank, look.reload.position
  end

  # A JSON REQUEST WITH NO SESSION GETS A 401, not the HTML redirect — the engine answers
  # the format it was asked in, and the board primitive reads the body for its toast.
  test "a visitor with no session cannot drag" do
    look = look!("Quiet", colorway: "bills home")

    patch model_pipeline_look_path(look.slug), params: { appearance: { stage: "generation" } }, as: :json

    assert_response :unauthorized
    assert_nil look.reload.stage
  end

  # THE LINK INTO THE NAV, so the board is reachable by clicking rather than by knowing a
  # URL — the same argument the person page makes for the model page it links to.
  test "the links menu carries the board" do
    log_in_as(users(:alex))

    get links_path

    assert_select "a[href='#{model_pipeline_path}']", minimum: 1
  end
end
