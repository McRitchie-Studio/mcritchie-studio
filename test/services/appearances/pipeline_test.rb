require "test_helper"

# [unit] THE BOARD'S GATHER — five lanes, real rows, and a FIXED number of queries.
#
# Appearances::LookReadingTest owns the RULE (which lane, and why). This owns the
# GATHER: that every fact a card prints is fetched once for the whole board rather than
# once per card, and that the lanes it hands the view are the ones the rows support.
#
# THE QUERY-COUNT TEST IS THE POINT OF THE OBJECT. The person page's own gallery reads
# the athlete's ImageCache rows per look (Appearances::ReferenceSet), which is correct
# for one look and an N+1 for a board of them. A card gaining a field must add a grouped
# query here, never a lookup inside the reading — and that is a property a comment
# cannot hold.
class Appearances::PipelineTest < ActiveSupport::TestCase
  setup do
    Appearance.delete_all
    AppearanceReferencePhoto.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    ImageCache.where(purpose: "headshot").delete_all

    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @athlete.update!(team_slug: "buffalo-bills", height_inches: 77, weight_lbs: 237)
  end

  def look!(descriptor:, person: @person, **attrs)
    Appearance.create!(person_slug: person.slug, descriptor: descriptor, **attrs)
  end

  def headshot!(athlete = @athlete)
    ImageCache.create!(owner: athlete, purpose: "headshot", variant: "400",
                       s3_key: "headshots/nfl/buffalo-bills/#{athlete.person_slug}/400.png",
                       content_type: "image/png")
  end

  def candidates!(look, count, chosen: 0)
    count.times do |i|
      AppearanceReferencePhoto.create!(appearance_slug: look.slug,
                                       image_url: "https://x.test/#{look.slug}-#{i}.jpg",
                                       source: AppearanceReferencePhoto::SOURCE_SEARCH,
                                       chosen: i < chosen)
    end
  end

  def sheet!(look, source: "openai", retired_at: nil)
    artifact = Artifact.create!(kind: "character_sheet", source: source,
                               image_url: "https://x.test/#{look.slug}.png", retired_at: retired_at)
    ArtifactSubject.create!(artifact_slug: artifact.slug, person_slug: look.person_slug,
                            appearance_slug: look.slug, ordinal: 1)
    artifact
  end

  def lane(board, key) = board[:lanes].find { |l| l.key == key }

  # ONE LOOK PER PERSON HERE, DELIBERATELY. The cached headshot hangs off the ATHLETE,
  # so every look on one person shares it — two looks on Josh Allen both reach Source
  # however little else they have. That is correct behaviour and it is exactly what made
  # the first version of this test wrong, so the lanes are proved across five people.
  test "every live look lands in exactly one lane and the totals add up" do
    bare = look!(descriptor: "Bare", person: people(:messi))
    uniform = look!(descriptor: "Uniform named", colorway: "bills home", person: people(:james_cook))
    headshot!
    sourced = look!(descriptor: "Sourced", colorway: "bills white")
    chosen = look!(descriptor: "Chosen", colorway: "bills navy", person: people(:cam_ward))
    candidates!(chosen, 8, chosen: 3)
    delivered = look!(descriptor: "Delivered", colorway: "bills game", person: people(:ray_davis))
    sheet!(delivered)

    board = Appearances::Pipeline.build

    assert_equal 5, board[:total]
    assert_equal 5, board[:lanes].sum(&:total), "a look in two lanes would double-count"
    assert_equal [bare.descriptor], lane(board, "designed").cards.map(&:descriptor)
    assert_equal [uniform.descriptor], lane(board, "defined").cards.map(&:descriptor)
    assert_equal [sourced.descriptor], lane(board, "source").cards.map(&:descriptor)
    assert_equal [chosen.descriptor], lane(board, "model").cards.map(&:descriptor)
    assert_equal [delivered.descriptor], lane(board, "generation").cards.map(&:descriptor)
  end

  test "a retired look is not on the board" do
    look!(descriptor: "Live", colorway: "bills home")
    look!(descriptor: "Gone", colorway: "bills away", retired_at: Time.current)

    assert_equal ["Live"], Appearances::Pipeline.build[:lanes].flat_map(&:cards).map(&:descriptor)
  end

  # A RETIRED IMAGE IS NOT A DELIVERY. Counting it would leave a card sitting in
  # Generation with nothing to show, which is the board lying about finished work — the
  # one thing this design forbids.
  test "a retired artifact does not count as a delivery" do
    look = look!(descriptor: "Retired sheet", colorway: "bills home")
    sheet!(look, retired_at: Time.current)

    reading = Appearances::Pipeline.reading_for(look.reload)

    assert_equal 0, reading.artifact_count
    assert_equal "defined", reading.derived_stage
  end

  test "the trade check reads the athlete's CURRENT team" do
    look = look!(descriptor: "Old jersey", colorway: "bengals white", team_slug: "cincinnati-bengals")
    sheet!(look)

    board = Appearances::Pipeline.build

    assert_equal 1, board[:stale_count]
    assert_equal [look.descriptor], lane(board, "defined").cards.map(&:descriptor)
    assert_empty lane(board, "generation").cards
  end

  # ANY CACHED HEADSHOT VARIANT COUNTS. Athlete::HEADSHOT_WIDTHS is a PREFERENCE list,
  # so keying the gather on "400" would report no reference for a look that has the
  # 100px crop and can still be built from it.
  test "the 100px headshot variant is a reference too" do
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "100",
                       s3_key: "headshots/nfl/buffalo-bills/josh-allen/100.png",
                       content_type: "image/png")
    look = look!(descriptor: "Small headshot", colorway: "bills home")

    assert Appearances::Pipeline.reading_for(look).headshot?
    assert_equal "source", Appearances::Pipeline.reading_for(look).derived_stage
  end

  # THE PROVENANCE IS DATA. A library will hold images from several generators, so the
  # newest one's `source` is reported and no vendor is named in the code that reads it.
  test "the newest live artifact's source is the card's provenance" do
    look = look!(descriptor: "Two sheets", colorway: "bills home")
    sheet!(look, source: "operator")
    travel_to(2.hours.from_now) { sheet!(look, source: "a-future-generator") }

    reading = Appearances::Pipeline.reading_for(look)

    assert_equal 2, reading.artifact_count
    assert_equal "a-future-generator", reading.artifact_source
  end

  test "the board counts hand placements the evidence would not have made" do
    headshot!
    look!(descriptor: "Pushed", colorway: "bills home", stage: "generation")

    board = Appearances::Pipeline.build

    assert_equal 1, board[:hand_placed_count]
    assert_equal ["Pushed"], lane(board, "generation").cards.map(&:descriptor)
  end

  # THE CAP HIDES CARDS, NEVER A NUMBER. A lane of two thousand cards is not a
  # 1000-foot view, so the column's count chip keeps the true total and the overflow is
  # reported beside it.
  test "a lane caps the cards it renders and still reports the true total" do
    (Appearances::Pipeline::LANE_LIMIT + 3).times do |i|
      look!(descriptor: "Defined #{i}", colorway: "bills home #{i}")
    end

    defined_lane = lane(Appearances::Pipeline.build, "defined")

    assert_equal Appearances::Pipeline::LANE_LIMIT + 3, defined_lane.total
    assert_equal Appearances::Pipeline::LANE_LIMIT, defined_lane.cards.length
    assert_equal 3, defined_lane.overflow
  end

  # THE GENESIS SEED IS GLOBAL FOR A LOOK NOBODY HAS DRAGGED, and that is worth pinning
  # because it is not what the concern's docstring leads a reader to expect. `stage` is
  # the operator's hand placement and is NULL on a fresh look, so
  # Rankable#board_next_position falls through its `board_zone_attr && zone_value` guard
  # and takes max(position) + 100 over the WHOLE table rather than within a lane
  # (measured 2026-09-27: 100, then 200). The consequence is the one the board wants —
  # a 100-gapped global creation order, so the newest look sits on top of its lane
  # before anybody drags anything.
  test "a look nobody has dragged is ranked globally and sorts newest first" do
    first = look!(descriptor: "First", colorway: "a")
    second = look!(descriptor: "Second", colorway: "b")

    assert_equal 100, first.position
    assert_equal 200, second.position
    lane_cards = lane(Appearances::Pipeline.build, "defined").cards.map(&:descriptor)

    assert_equal [second.descriptor, first.descriptor], lane_cards, "highest rank on top, per board_ordered"
  end

  # A DRAG RESTAMPS ONE LANE, and the rank it writes is the lane's own — this is the
  # "stage zone ranks independently per lane" property the task asked for, proved through
  # the same Rankable#reposition! the shared reorder action calls.
  test "a lane restamps to its own 100-gapped ranks without touching another lane" do
    top = look!(descriptor: "Top", colorway: "a", stage: "model")
    middle = look!(descriptor: "Middle", colorway: "b", stage: "model")
    elsewhere = look!(descriptor: "Elsewhere", colorway: "c", stage: "generation")
    before = elsewhere.position

    Appearance.reposition!([middle.slug, top.slug], id_attr: :slug)

    assert_equal 200, middle.reload.position, "the top card of the lane holds the highest rank"
    assert_equal 100, top.reload.position
    assert_equal before, elsewhere.reload.position, "a reorder in one lane leaves the others alone"
  end

  # THE FIXED-QUERY PROPERTY. Asserted as "the count does not grow with the number of
  # looks" rather than as a magic number, because the magic number is what a new grouped
  # query legitimately changes and a brittle assertion gets deleted rather than fixed.
  test "the board's query count does not grow with the number of looks" do
    headshot!
    3.times { |i| candidates!(look!(descriptor: "Look #{i}", colorway: "c#{i}"), 4, chosen: 2) }
    small = count_queries { Appearances::Pipeline.build }

    12.times { |i| candidates!(look!(descriptor: "More #{i}", colorway: "m#{i}"), 4, chosen: 2) }
    large = count_queries { Appearances::Pipeline.build }

    assert_equal small, large,
                 "the gather must be grouped over the whole board — #{small} queries for 3 looks " \
                 "and #{large} for 15 is a per-card lookup"
  end

  test "an empty board still hands the view all five lanes" do
    board = Appearances::Pipeline.build

    assert_equal Appearances::LookReading::STAGES, board[:lanes].map(&:key)
    assert_equal 0, board[:total]
    assert(board[:lanes].all? { |l| l.cards.empty? && l.total.zero? && l.overflow.zero? })
  end

  test "a one-look reading takes the same path the board does" do
    look = look!(descriptor: "Solo", colorway: "bills home")
    candidates!(look, 6, chosen: 2)

    solo = Appearances::Pipeline.reading_for(look)
    from_board = lane(Appearances::Pipeline.build, "model").cards.first

    assert_equal from_board.derived_stage, solo.derived_stage
    assert_equal from_board.blocker, solo.blocker
    assert_equal from_board.chosen_count, solo.chosen_count
  end

  private

  def count_queries
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].start_with?("BEGIN", "COMMIT")
    end
    begin
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    queries.length
  end
end
