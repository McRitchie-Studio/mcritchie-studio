require "test_helper"

# THE ACT: ONE PERSON, ACQUIRED OR RE-CHECKED.
#
# Driven through a FAKE PROVIDER, which is the point of the seam — these tests
# describe the decision rules and touch no network. The rules under test are the ones
# that produce silent wrongness when they are wrong: who wins a disagreement, when a
# duplicate human gets created, and whether "nothing came back" is reported as a fact
# about the player or a fact about the source.
class Athletes::AcquireOrValidateTest < ActiveSupport::TestCase
  # A provider that answers from hashes and records what it was asked.
  class FakeSource
    attr_reader :league_searches, :roster_searches

    def initialize(by_id: {}, by_roster: {}, in_league: {}, raise_on: nil)
      @by_id = by_id
      @by_roster = by_roster
      @in_league = in_league
      @raise_on = raise_on
      @league_searches = []
      @roster_searches = []
    end

    def source = :fake

    def find(source_id:)
      raise Athletes::SourceUnavailable, @raise_on if @raise_on

      @by_id[source_id.to_s]
    end

    def find_on_roster(team:, name:)
      raise Athletes::SourceUnavailable, @raise_on if @raise_on

      @roster_searches << [team.to_s, name]
      @by_roster[[team.to_s, Athletes::NameKey.for(name)]]
    end

    def find_in_league(name:)
      raise Athletes::SourceUnavailable, @raise_on if @raise_on

      @league_searches << name
      @in_league[Athletes::NameKey.for(name)]
    end

    def roster(team:) = []
  end

  def profile(**overrides)
    Athletes::SourceProfile.new(
      **{ source: :fake, source_id: "9001", first_name: "Rook", last_name: "Runner",
          jersey_number: 30, position: "RB", team_slug: "buffalo-bills",
          height_inches: 70, weight_lbs: 205,
          headshot_url: "https://example.test/9001.png", college: "Boise State",
          unparsed: {} }.merge(overrides)
    )
  end

  def outcome_for(report, field) = report.changes.find { |c| c.field == field }&.outcome

  def change_for(report, field) = report.changes.find { |c| c.field == field }

  def act(source, **options)
    Athletes::AcquireOrValidate.new(provider: source, cache_headshot: false, **options)
  end

  setup { teams(:buffalo_bills) }

  # ─── ACQUIRE ────────────────────────────────────────────────────────────────

  test "acquires a person who has no rows at all" do
    source = FakeSource.new(by_id: { "9001" => profile })

    report = nil
    assert_difference -> { Person.count } => 1, -> { Athlete.count } => 1 do
      report = act(source).call(source_id: "9001")
    end

    assert report.ok?
    assert_equal :acquire, report.mode
    assert_equal %w[person:rook-runner athlete:rook-runner], report.created

    athlete = Athlete.find_by(person_slug: "rook-runner")
    assert_equal "9001", athlete.espn_id
    assert_equal "buffalo-bills", athlete.team_slug
    assert_equal 30, athlete.jersey_number, "the column this act added"
    assert_equal "RB", athlete.position
    assert_equal 70, athlete.height_inches
    assert_equal 205, athlete.weight_lbs
    assert_equal "football", athlete.sport
    assert athlete.person.athlete?, "the person is flagged as an athlete"
  end

  test "every field of a row that did not exist reports filled, not unchanged" do
    # The report is snapshotted BEFORE the rows are created, so an acquire cannot
    # describe the names it just wrote as having always been there.
    source = FakeSource.new(by_id: { "9001" => profile })

    report = act(source).call(source_id: "9001")

    %i[espn_id team_slug jersey_number position height_inches weight_lbs
       first_name last_name espn_headshot_url].each do |field|
      assert_equal :filled, outcome_for(report, field), "#{field} should read filled on an acquire"
    end
    refute report.stale?, "a person we had never asked about is not STALE, merely new"
  end

  test "an existing person with no athlete row gains one" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: false)
    source = FakeSource.new(by_id: { "9001" => profile })

    report = nil
    assert_difference -> { Athlete.count } => 1, -> { Person.count } => 0 do
      report = act(source).call(source_id: "9001")
    end

    assert_equal :acquire, report.mode
    assert_equal ["athlete:rook-runner"], report.created
    assert person.reload.athlete?, "acquiring an athlete record flags the person"
  end

  # ─── VALIDATE ───────────────────────────────────────────────────────────────

  test "validate fills the blanks and leaves agreements alone" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9001",
                    team_slug: "buffalo-bills", position: "RB")
    source = FakeSource.new(by_id: { "9001" => profile })

    report = act(source).call(person: "rook-runner")

    assert_equal :validate, report.mode
    assert_empty report.created
    assert_equal :unchanged, outcome_for(report, :team_slug)
    assert_equal :unchanged, outcome_for(report, :position)
    assert_equal :filled, outcome_for(report, :height_inches)
    assert_equal 70, Athlete.find_by(person_slug: "rook-runner").height_inches
    refute report.stale?, "filling a blank is not staleness — we had simply never asked"
  end

  test "a re-run writes nothing and says so" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9001",
                    team_slug: "buffalo-bills", position: "RB", jersey_number: 30,
                    height_inches: 70, weight_lbs: 205,
                    espn_headshot_url: "https://example.test/9001.png")
    source = FakeSource.new(by_id: { "9001" => profile })

    report = act(source).call(person: "rook-runner")

    assert_empty report.written
    assert report.changes.all? { |c| c.outcome == :unchanged }, report.changes.map(&:outcome).inspect
  end

  # ─── A TRADE: the motivating case ───────────────────────────────────────────

  test "a trade updates the team and is named as a trade" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9001",
                              team_slug: "miami-dolphins", position: "RB")
    source = FakeSource.new(by_id: { "9001" => profile })

    report = act(source).call(person: "rook-runner")

    change = change_for(report, :team_slug)
    assert_equal :traded, change.outcome
    assert_equal "miami-dolphins", change.stored
    assert_equal "buffalo-bills", change.incoming
    assert_equal "buffalo-bills", athlete.reload.team_slug, "the roster fact IS taken"
    assert report.stale?, "the source disagreeing with a stored value is what stale means"
  end

  test "the stored team is searched first, then the whole league" do
    # A TRADE MEANS THE STORED TEAM IS THE ONE ROSTER HE IS NO LONGER ON, so the
    # first miss is the expected result and must widen rather than refuse. Measured
    # against the live source on 2026-09-27 with Bo Nix stored against Cincinnati.
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", team_slug: "miami-dolphins")
    source = FakeSource.new(in_league: { "rookrunner" => profile })

    report = act(source).call(person: "rook-runner")

    assert_equal [["mia", "Rook Runner"]], source.roster_searches, "the stored team is tried first"
    assert_equal ["Rook Runner"], source.league_searches, "and the miss widens to the league"
    assert_equal :traded, outcome_for(report, :team_slug)
  end

  test "the league walk is skipped when it is switched off" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", team_slug: "miami-dolphins")
    source = FakeSource.new(in_league: { "rookrunner" => profile })

    report = act(source, search_league: false).call(person: "rook-runner")

    assert_equal :not_on_source, report.status
    assert_empty source.league_searches
    assert_match(/league-wide search is switched off/, report.message)
  end

  test "a person on no roster anywhere is reported, not invented" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", team_slug: "miami-dolphins")
    source = FakeSource.new

    report = act(source).call(person: "rook-runner")

    assert_equal :not_on_source, report.status
    assert_match(/on no fake roster in the league/, report.message)
  end

  # ─── THE OVERWRITE RULE ─────────────────────────────────────────────────────

  test "a held field disagreement keeps ours and reports the conflict" do
    # The measurement behind this rule: T.J. Watt is stored EDGE (from PFF, whose
    # vocabulary is finer) and ESPN's "LB" normalizes to LB. A source-wins rule on
    # position would quietly demote every 3-4 edge rusher in the league.
    person = Person.create!(first_name: "Edge", last_name: "Rusher", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9002",
                              position: "EDGE", height_inches: 76)
    source = FakeSource.new(by_id: { "9002" => profile(source_id: "9002", first_name: "Edge",
                                                      last_name: "Rusher", position: "LB",
                                                      height_inches: 75) })

    report = act(source).call(person: "edge-rusher")

    assert_equal :conflict, outcome_for(report, :position)
    assert_equal :conflict, outcome_for(report, :height_inches)
    assert_equal "EDGE", athlete.reload.position, "ours is KEPT"
    assert_equal 76, athlete.height_inches
    assert report.stale?
    assert_equal 2, report.conflicts.length
    assert_match(/adopt the source's value/, change_for(report, :position).note)
  end

  test "adopt takes the source's value for exactly the named field" do
    person = Person.create!(first_name: "Edge", last_name: "Rusher", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9002",
                              position: "EDGE", height_inches: 76)
    source = FakeSource.new(by_id: { "9002" => profile(source_id: "9002", first_name: "Edge",
                                                      last_name: "Rusher", position: "LB",
                                                      height_inches: 75) })

    report = act(source, adopt: %w[position]).call(person: "edge-rusher")

    assert_equal :adopted, outcome_for(report, :position)
    assert_equal "LB", athlete.reload.position
    assert_equal :conflict, outcome_for(report, :height_inches), "an un-named field is still held"
    assert_equal 76, athlete.height_inches
    assert report.stale?, "adopting settles the argument; it does not un-have it"
  end

  test "an adopted field is the only disagreement and still reads stale" do
    # ISOLATED DELIBERATELY. The adopt test above also carries a height conflict, which
    # makes the report stale on its own — so it cannot tell whether `adopted` counts.
    # A mutation that dropped :adopted from Change#disagreement? survived that test and
    # dies against this one.
    person = Person.create!(first_name: "Edge", last_name: "Rusher", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9002",
                    team_slug: "buffalo-bills", position: "EDGE", jersey_number: 30,
                    height_inches: 70, weight_lbs: 205,
                    espn_headshot_url: "https://example.test/9002.png")
    source = FakeSource.new(by_id: { "9002" => profile(source_id: "9002", first_name: "Edge",
                                                      last_name: "Rusher", position: "LB",
                                                      headshot_url: "https://example.test/9002.png") })

    report = act(source, adopt: %w[position]).call(person: "edge-rusher")

    assert_equal [:adopted], report.changes.select(&:disagreement?).map(&:outcome),
                 "position must be the ONLY disagreement in this report"
    assert report.stale?
  end

  test "only held fields are adoptable" do
    error = assert_raises(ArgumentError) { Athletes::AcquireOrValidate.new(adopt: %w[team_slug]) }
    assert_match(/not adoptable: team_slug/, error.message)
    assert_match(/position/, error.message, "the refusal names what IS adoptable")
  end

  test "a name the source spells differently is a conflict, never a rewrite" do
    person = Person.create!(first_name: "A.J.", last_name: "Cole", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9003")
    source = FakeSource.new(by_id: { "9003" => profile(source_id: "9003", first_name: "AJ",
                                                      last_name: "Cole") })

    report = act(source).call(person: "a-j-cole")

    assert_equal :conflict, outcome_for(report, :first_name)
    assert_equal "A.J.", person.reload.first_name, "a hand-corrected name is not clobbered"
  end

  # ─── IDENTITY ───────────────────────────────────────────────────────────────

  test "a stored id that disagrees refuses the whole act" do
    # Reached by naming the SOURCE id: the row is then resolved by name, and the name
    # leads to a row that already claims a different identity.
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "1111",
                              team_slug: "miami-dolphins")
    source = FakeSource.new(by_id: { "9001" => profile(source_id: "9001") })

    report = act(source).call(source_id: "9001")

    assert_equal :identity_conflict, report.status
    assert_match(/already holds fake id 1111/, report.message)
    assert_match(/9001/, report.message)
    assert_equal "miami-dolphins", athlete.reload.team_slug, "nothing at all was written"
    assert_empty report.changes
  end

  test "a stored id the source no longer carries refuses instead of crashing" do
    # Found by a test that meant to exercise something else: the act used to call
    # #identified? on the nil the provider returned. A dead id is an ordinary fact
    # about our data and must come back as a refusal naming the id.
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "1111",
                    team_slug: "miami-dolphins")
    source = FakeSource.new(in_league: { "rookrunner" => profile })

    report = act(source).call(person: "rook-runner")

    assert_equal :stale_source_id, report.status
    assert_match(/holds fake id 1111/, report.message)
    assert_empty source.league_searches, "a dead id must NOT be silently re-bound by name"

    # THE PRINTED REMEDY HAS TO BE THE ONE THAT WORKS. Measured against the live
    # source first: the message used to say "re-bind with source_id:", and doing that
    # walks straight into #identity_guard's refusal, because the dead id is still on
    # the row. So the message names clearing the id, and this follows it.
    assert_match(/update!\(espn_id: nil\)/, report.message)
    Athlete.find_by(person_slug: "rook-runner").update!(espn_id: nil)
    again = act(source).call(person: "rook-runner")
    assert again.ok?, "the remedy the refusal printed must actually unblock the act"
    assert_equal "9001", Athlete.find_by(person_slug: "rook-runner").espn_id
  end

  test "a near-match name refuses rather than creating a second row for one human" do
    # Measured: ESPN says "AJ Cole" and Person.find_by_name cannot see "A.J. Cole",
    # so trusting the miss would file a duplicate punter.
    existing = Person.create!(first_name: "A.J.", last_name: "Cole", athlete: true)
    source = FakeSource.new(by_id: { "9003" => profile(source_id: "9003", first_name: "AJ",
                                                      last_name: "Cole") })

    report = nil
    assert_no_difference -> { Person.count } do
      report = act(source).call(source_id: "9003")
    end

    assert_equal :ambiguous_name, report.status
    assert_match(existing.slug, report.message)
    assert_match(/source_id/, report.message, "the refusal names the way forward")
  end

  test "an id already on file binds to that row even under another spelling" do
    # The escape hatch the refusal above points at: identity is the id, never a name.
    person = Person.create!(first_name: "A.J.", last_name: "Cole", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9003")
    source = FakeSource.new(by_id: { "9003" => profile(source_id: "9003", first_name: "AJ",
                                                      last_name: "Cole", jersey_number: 6) })

    report = nil
    assert_no_difference -> { Person.count } do
      report = act(source).call(source_id: "9003")
    end

    assert_equal :validate, report.mode
    assert_equal "a-j-cole", report.person_slug
    assert_equal 6, Athlete.find_by(espn_id: "9003").jersey_number
  end

  test "a source answer missing half a name cannot become a new person" do
    source = FakeSource.new(by_id: { "9004" => profile(source_id: "9004", first_name: "Solo",
                                                      last_name: nil) })

    report = nil
    assert_no_difference -> { Person.count } do
      report = act(source).call(source_id: "9004")
    end

    assert_equal :unnamed, report.status
  end

  # ─── WHAT THE SOURCE COULD NOT SAY ──────────────────────────────────────────

  test "an unreadable display string is reported with its raw text and nothing is written" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9001")
    source = FakeSource.new(by_id: { "9001" => profile(height_inches: nil,
                                                      unparsed: { "height_inches" => "about six foot" }) })

    report = act(source).call(person: "rook-runner")

    change = change_for(report, :height_inches)
    assert_equal :unreadable, change.outcome
    assert_match(/about six foot/, change.note)
    assert_nil athlete.reload.height_inches
    refute change.wrote?
  end

  test "a field the source simply lacks writes nothing and clears nothing" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9001",
                              weight_lbs: 205)
    source = FakeSource.new(by_id: { "9001" => profile(weight_lbs: nil) })

    report = act(source).call(person: "rook-runner")

    assert_equal :absent, outcome_for(report, :weight_lbs)
    assert_equal 205, athlete.reload.weight_lbs, "a silent source must never blank a column"
  end

  test "an unreachable source is a refusal about the source, not about the player" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9001")
    source = FakeSource.new(raise_on: "503 from the feed")

    report = act(source).call(person: "rook-runner")

    assert_equal :unavailable, report.status
    assert_match(/503 from the feed/, report.message)
  end

  test "a person nobody has heard of is refused before the source is asked" do
    source = FakeSource.new

    report = act(source).call(person: "nobody-at-all")

    assert_equal :no_such_person, report.status
  end

  test "the source having no such id is reported as such" do
    source = FakeSource.new

    report = act(source).call(source_id: "does-not-exist")

    assert_equal :not_found, report.status
  end

  test "naming no subject is a programming error, not a refusal" do
    assert_raises(ArgumentError) { act(FakeSource.new).call }
  end

  # ─── DRY RUN ────────────────────────────────────────────────────────────────

  test "a dry run creates nothing, writes nothing, and still reports everything" do
    source = FakeSource.new(by_id: { "9001" => profile })

    report = nil
    assert_no_difference ["Person.count", "Athlete.count"] do
      report = act(source, dry_run: true).call(source_id: "9001")
    end

    assert report.ok?
    assert_equal :acquire, report.mode
    assert_equal %w[person:rook-runner athlete:rook-runner], report.created,
                 "it still names the rows it WOULD create"
    assert_equal "rook-runner", report.person_slug,
                 "an unsaved person has no slug yet, so the report falls back to name_slug"
    assert_equal :filled, outcome_for(report, :jersey_number)
    assert report.dry_run
  end

  test "a dry run over an existing person leaves every column alone" do
    person = Person.create!(first_name: "Edge", last_name: "Rusher", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9002",
                              position: "EDGE", team_slug: "miami-dolphins")
    source = FakeSource.new(by_id: { "9002" => profile(source_id: "9002", first_name: "Edge",
                                                      last_name: "Rusher", position: "LB") })

    report = act(source, adopt: %w[position], dry_run: true).call(person: "edge-rusher")

    assert_equal :adopted, outcome_for(report, :position)
    assert_equal :traded, outcome_for(report, :team_slug)
    assert_equal "EDGE", athlete.reload.position
    assert_equal "miami-dolphins", athlete.team_slug
  end

  # ─── THE HEADSHOT ───────────────────────────────────────────────────────────

  test "the headshot is cached and the report reads the stored keys back" do
    source = FakeSource.new(by_id: { "9001" => profile })
    cached_with = nil
    faked = lambda do |owner:, purpose:, source_url:, key_prefix:, widths:, content_type:|
      cached_with = { key_prefix: key_prefix, widths: widths, url: source_url, type: content_type }
      (["original"] + widths.map(&:to_s)).each do |variant|
        ImageCache.create!(owner: owner, purpose: purpose, variant: variant,
                           s3_key: "#{key_prefix}/#{variant}.png", source_url: source_url,
                           bytes: 1, content_type: content_type)
      end
    end

    report = Studio::ImageCache.stub(:cache!, faked) do
      Athletes::AcquireOrValidate.new(provider: source).call(source_id: "9001")
    end

    assert_equal :cached, report.headshot[:status]
    assert_equal "headshots/nfl/buffalo-bills/rook-runner", cached_with[:key_prefix],
                 "the folder comes from Athlete#headshot_key_prefix, after the team was written"
    assert_equal Athlete::HEADSHOT_WIDTHS, cached_with[:widths]
    # READ BACK, NOT REBUILT: a re-key moves objects, so a derived path names objects
    # that are no longer there.
    assert_equal ImageCache.where(purpose: "headshot").map(&:s3_key).sort, report.headshot[:keys]
  end

  test "a headshot failure is reported and does not fail the act" do
    # The one credential-dependent step in an act that must run on a desk with no
    # bucket. The source url is stored either way, which is what nfl:upload_headshots
    # needs to finish the job later.
    source = FakeSource.new(by_id: { "9001" => profile })
    exploding = ->(**) { raise Studio::S3::NotConfigured, "no bucket here" }

    report = Studio::ImageCache.stub(:cache!, exploding) do
      Athletes::AcquireOrValidate.new(provider: source).call(source_id: "9001")
    end

    assert report.ok?, "the data is filled even though the image was not"
    assert_equal :failed, report.headshot[:status]
    assert_match(/no bucket here/, report.headshot[:reason])
    assert_equal "https://example.test/9001.png",
                 Athlete.find_by(person_slug: "rook-runner").espn_headshot_url
  end

  test "an already-cached headshot is not re-fetched" do
    person = Person.create!(first_name: "Rook", last_name: "Runner", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "9001",
                              team_slug: "buffalo-bills")
    (["original"] + Athlete::HEADSHOT_WIDTHS.map(&:to_s)).each do |variant|
      ImageCache.create!(owner: athlete, purpose: "headshot", variant: variant,
                         s3_key: "headshots/nfl/buffalo-bills/rook-runner/#{variant}.png",
                         bytes: 1, content_type: "image/png")
    end
    source = FakeSource.new(by_id: { "9001" => profile })

    report = Studio::ImageCache.stub(:cache!, ->(**) { flunk "must not re-cache" }) do
      Athletes::AcquireOrValidate.new(provider: source).call(source_id: "9001")
    end

    assert_equal :already, report.headshot[:status]
  end

  test "a source with no headshot says so rather than reporting a failure" do
    source = FakeSource.new(by_id: { "9001" => profile(headshot_url: nil) })

    report = Athletes::AcquireOrValidate.new(provider: source).call(source_id: "9001")

    assert_equal :absent, report.headshot[:status]
    assert_equal :absent, outcome_for(report, :espn_headshot_url)
  end
end
