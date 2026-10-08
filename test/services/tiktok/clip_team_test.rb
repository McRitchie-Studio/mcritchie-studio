require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [unit] Tiktok::ClipTeam — whose team a clip's caption is about: the clip's
# lead swapped athlete, from the alt video's snapshot, by the documented order
# (target, first lead, first swapped present, the alt video's first swap), and
# that athlete's team (the look's, else the athlete's current). Synthetic people
# on the tiled demo: Person 1 is on screen throughout and is every chunk's
# target; Person 2 is partial, in the first half only.
class Tiktok::ClipTeamTest < ActiveSupport::TestCase
  setup do
    @video = TiledVideo.seed!
    @alpha, @alpha_look = athlete("Alpha", team: "buffalo-bills")
    @beta, @beta_look = athlete("Beta", team: "miami-dolphins")
  end

  def athlete(name, team: nil)
    person = Person.create!(athlete: true, first_name: "Test", last_name: "Tiktok #{name}")
    [person, person.appearances.live.create!(descriptor: "Home", team_slug: team)]
  end

  def swap!(ordinal, person, look)
    @video.video_performers.find_by!(ordinal:).update!(recast_person_slug: person.slug, recast_appearance_slug: look.slug, recast_keep: false)
  end

  def build = AltVideo.build_from!(@video.reload)

  def choose(alt, ordinal) = Tiktok::ClipTeam.new(alt.clips.find { |c| c.chunk_ordinal == ordinal }).call

  test "the clip's target leads when the alt video swaps them" do
    swap!(1, @alpha, @alpha_look)
    swap!(2, @beta, @beta_look)
    choice = choose(build, 1)

    assert_equal ["Test Tiktok Alpha", "the clip's target", "buffalo-bills", "look"],
                 [choice.entry.person_name, choice.rule, choice.team.slug, choice.team_source]
  end

  test "with the target kept, the first swapped lead in the window wins" do
    @video.video_performers.find_by!(ordinal: 2).update!(sightings: [9, 12, 15].map { |s| { "t_ms" => s * 1000, "visibility" => "clear" } })
    swap!(2, @beta, @beta_look)
    choice = choose(build, 1)

    assert_equal ["Test Tiktok Beta", "the first lead in the clip", "miami-dolphins"],
                 [choice.entry.person_name, choice.rule, choice.team.slug]
  end

  test "with no lead swapped, the first swapped person on screen wins" do
    swap!(2, @beta, @beta_look) # partial sightings only: background
    choice = choose(build, 1)

    assert_equal ["Test Tiktok Beta", "the first swapped person in the clip"], [choice.entry.person_name, choice.rule]
  end

  test "a window that swaps nobody falls back to the alt video's first swap" do
    swap!(2, @beta, @beta_look) # Person 2 is not in chunk 3 (40-65 s)
    choice = choose(build, 3)

    assert_equal ["Test Tiktok Beta", "the alt video's first swap"], [choice.entry.person_name, choice.rule]
  end

  test "two leads tie to the lower performer ordinal" do
    @video.video_performers.find_by!(ordinal: 2).update!(sightings: [9, 12, 15].map { |s| { "t_ms" => s * 1000, "visibility" => "clear" } })
    @video.video_performers.find_by!(ordinal: 1).update!(recast_keep: true)
    swap!(2, @beta, @beta_look)
    alt = build
    # Re-label chunk 1 so neither swapped person is its target, with Person 1 swapped too.
    chunk = @video.video_chunks.find_by!(ordinal: 1)
    chunk.update!(target_performer: nil)
    alt.update_column(:swaps, alt.swaps + [{ "performer_ordinal" => 1, "person_slug" => @alpha.slug, "appearance_slug" => @alpha_look.slug,
                                             "person_name" => "Test Tiktok Alpha", "look_name" => "Home" }])
    choice = choose(alt.reload, 1)

    assert_equal ["Test Tiktok Alpha", "the first lead in the clip"], [choice.entry.person_name, choice.rule]
  end

  test "the look's team wins over the athlete's current team; the athlete's is the fallback" do
    Athlete.create!(person_slug: @alpha.slug, sport: "football", slug: "test-tiktok-alpha-athlete", team_slug: "miami-dolphins")
    swap!(1, @alpha, @alpha_look)
    assert_equal ["buffalo-bills", "look"], choose(build, 1).then { |c| [c.team.slug, c.team_source] }

    @alpha_look.update!(team_slug: nil)
    assert_equal ["miami-dolphins", "athlete"], choose(build, 1).then { |c| [c.team.slug, c.team_source] }
  end

  test "an athlete with no team, or an alt video that swaps nobody, is refused" do
    @alpha_look.update!(team_slug: nil)
    swap!(1, @alpha, @alpha_look)
    error = assert_raises(Tiktok::ClipTeam::Refused) { choose(build, 1) }
    assert_match(/Test Tiktok Alpha has no team/, error.message)

    @video.video_performers.update_all(recast_keep: true)
    error = assert_raises(Tiktok::ClipTeam::Refused) { choose(build, 1) }
    assert_match(/swaps nobody/, error.message)
  end

  # Production, 2026-10-08: the look said dallas-cowboys, the teams table was
  # empty, and the refusal read "has no team". A slug with no row is its own
  # refusal, and it names the slug.
  test "a look that names a team with no row is refused by name, not as having no team" do
    @alpha_look.update_column(:team_slug, "test-comets") # a row from before the validation
    swap!(1, @alpha, @alpha_look)
    error = assert_raises(Tiktok::ClipTeam::Refused) { choose(build, 1) }

    assert_match(/Test Tiktok Alpha: the look "Home" names team test-comets, which is not in the teams table/, error.message)
    assert_no_match(/has no team/, error.message)
  end

  test "a look whose team row is missing is refused even when the athlete's own team is on file" do
    Athlete.create!(person_slug: @alpha.slug, sport: "football", slug: "test-tiktok-alpha-athlete", team_slug: "miami-dolphins")
    @alpha_look.update_column(:team_slug, "test-comets")
    swap!(1, @alpha, @alpha_look)

    error = assert_raises(Tiktok::ClipTeam::Refused) { choose(build, 1) }
    assert_match(/the look "Home" names team test-comets/, error.message)
  end

  test "an athlete record that names a team with no row is refused by name" do
    Athlete.create!(person_slug: @alpha.slug, sport: "football", slug: "test-tiktok-alpha-athlete", team_slug: "test-comets")
    @alpha_look.update!(team_slug: nil)
    swap!(1, @alpha, @alpha_look)

    error = assert_raises(Tiktok::ClipTeam::Refused) { choose(build, 1) }
    assert_match(/Test Tiktok Alpha: the athlete record names team test-comets, which is not in the teams table/, error.message)
    assert_no_match(/has no team/, error.message)
  end
end
