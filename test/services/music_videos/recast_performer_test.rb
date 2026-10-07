require "test_helper"
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [integration] The recast service and the prompts it keeps: a recast names
# the athlete and look in every stored prompt whose swap target it is, a
# change or a clear rewrites them, and a look or person that goes away takes
# its name out. Every artist and athlete here is synthetic.
class MusicVideosRecastPerformerTest < ActiveSupport::TestCase
  setup do
    @video = RecastVideo.seed!
    @athlete = RecastVideo.athlete!
    @home, @away = @athlete.appearances.order(:created_at, :id).to_a
    @jacket = @video.video_performers.find_by!(ordinal: 1)
    @doorway = @video.video_performers.find_by!(ordinal: 2)
  end

  def recast(performer, **choice) = MusicVideos::RecastPerformer.new(performer).call(**choice)
  def prompts = @video.reload.video_chunks.map(&:prompt)

  test "a seeded cinematic chunk names nobody, and never says music video" do
    assert_equal 4, prompts.size
    prompts.each do |prompt|
      assert prompt.start_with?("Replace the main person on screen in this video with {athlete}, the football player.")
      assert_not_includes prompt, "music video"
    end
  end

  test "a recast on a confirmed cast fills the athlete and look into every chunk he is in" do
    assert @video.cast_confirmed?
    recast(@jacket, person_slug: @athlete.slug, appearance_slug: @away.slug)

    assert_equal [@athlete.slug, @away.slug, false], @jacket.reload.values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
    prompts.each do |prompt|
      assert prompt.start_with?("This clip is from a video.")
      assert_includes prompt, "- Person A (lead) -> Test Athlete Alpha, Away White (character sheet 1)"
      assert_not_includes prompt, "{athlete}"
      assert_not_includes prompt, "music video"
    end
  end

  test "changing the look, keeping, and clearing each rewrite the stored prompts" do
    recast(@jacket, person_slug: @athlete.slug, appearance_slug: @away.slug)
    recast(@jacket, person_slug: @athlete.slug, appearance_slug: @home.slug)
    assert(prompts.all? { |p| p.include?("Person A (lead) -> Test Athlete Alpha, Home Blue") && p.exclude?("Away White") })

    recast(@jacket, keep: true)
    assert @jacket.reload.recast_keep?
    assert_equal [@athlete.slug, @home.slug], @jacket.values_at(:recast_person_slug, :recast_appearance_slug), "off remembers"
    assert(prompts.all? { |p| p.include?("{athlete}") && p.exclude?("Test Athlete Alpha") })

    recast(@jacket, swap: true)
    assert @jacket.reload.recast?
    assert(prompts.all? { |p| p.include?("Person A (lead) -> Test Athlete Alpha, Home Blue") }, "on again names him with no re-pick")

    recast(@jacket, clear: true)
    assert_equal [nil, nil, false], @jacket.reload.values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
  end

  test "only the chunks a recast performer is in are rewritten" do
    # The woman in the doorway is seen at 9, 12 and 30 s: chunks 1 and 2 only.
    recast(@doorway, person_slug: @athlete.slug, appearance_slug: @home.slug)

    named = prompts.map { |p| p.include?("- Person B (background) -> Test Athlete Alpha, Home Blue (character sheet 1)") }
    assert_equal [true, true, false, false], named
    assert(prompts.last(2).all? { |p| p.include?("{athlete}") })
  end

  test "the labelled target wins when recast; a kept target hands the prompt to a recast person in the window" do
    video = TiledVideo.seed! # Person 1 is Test Artist A, the labelled target of every chunk; Person 2 an extra.
    star, extra = video.video_performers.to_a
    recast(extra, person_slug: @athlete.slug, appearance_slug: @home.slug)
    chunk = video.reload.video_chunks.first
    assert_equal extra, chunk.swap_target
    assert_includes chunk.prompt, "- Person B (background) -> Test Athlete Alpha, Home Blue (character sheet 1)"
    assert_not_includes chunk.prompt, "Person A", "the kept star is not in the swap list"
    assert_includes chunk.prompt, "Keep everyone else exactly as they are."
    assert_equal star, video.video_chunks.last.swap_target, "the last chunk never shows the extra"

    recast(star, person_slug: @athlete.slug, appearance_slug: @away.slug)
    chunk = video.reload.video_chunks.first
    assert_equal star, chunk.swap_target
    assert_includes chunk.prompt, "- Person A (lead) -> Test Athlete Alpha, Away White (character sheet 1)"
    assert_includes chunk.prompt, "- Person B (background) -> Test Athlete Alpha, Home Blue (character sheet 2)",
                    "every swapped person in the window, leads and background"
    candidate = video.clip_candidates.first
    assert_includes candidate.prompt, "Person A (lead) -> Test Athlete Alpha, Away White"
  end

  test "an athlete without a look, a stranger's look and no choice at all are refused and change nothing" do
    other = Person.create!(first_name: "Test", last_name: "Athlete Beta", athlete: true)
    theirs = other.appearances.create!(descriptor: "Road Grey")
    before = prompts

    assert_raises(MusicVideos::RecastPerformer::Refused) { recast(@jacket, person_slug: @athlete.slug) }
    assert_raises(MusicVideos::RecastPerformer::Refused) { recast(@jacket) }
    assert_raises(ActiveRecord::RecordInvalid) { recast(@jacket, person_slug: @athlete.slug, appearance_slug: theirs.slug) }

    assert @jacket.reload.recast_keep?
    assert_equal before, prompts
  end

  test "a new chunk set is filled from the recast already on the cast" do
    recast(@jacket, person_slug: @athlete.slug, appearance_slug: @away.slug)
    MusicVideos::ReplaceClips.new(@video.reload, RecastVideo.chunk_rows(@video), kind: "chunk").call

    assert(prompts.all? { |p| p.include?("Person A (lead) -> Test Athlete Alpha, Away White") })
  end

  test "destroying the look leaves the athlete, asks for another look, and drops its name from the prompts" do
    recast(@jacket, person_slug: @athlete.slug, appearance_slug: @away.slug)
    @away.destroy!

    assert @jacket.reload.recast_pending?
    assert_equal [1], @video.reload.recast_open.map(&:ordinal)
    assert(prompts.all? { |p| p.include?("- Person A (lead) -> Test Athlete Alpha (character sheet 1)") })
  end

  test "destroying the athlete frees the performer and blanks the prompts again" do
    recast(@jacket, person_slug: @athlete.slug, appearance_slug: @away.slug)
    @athlete.destroy!

    assert_equal [nil, nil], @jacket.reload.values_at(:recast_person_slug, :recast_appearance_slug)
    assert(prompts.all? { |p| p.include?("{athlete}") && p.exclude?("Test Athlete Alpha") })
  end

  test "an athlete with no look yet is saved alone: named in the prompts, the card still open" do
    lookless = Person.create!(first_name: "Test", last_name: "Athlete Gamma", athlete: true)

    recast(@jacket, person_slug: lookless.slug)

    assert @jacket.reload.recast_pending?
    assert_not @jacket.resolved?, "an athlete with no look does not close a card"
    assert_equal [1], @video.reload.recast_open.map(&:ordinal)
    assert(prompts.all? { |p| p.include?("- Person A (lead) -> Test Athlete Gamma (character sheet 1)") })
  end

  test "the typeahead finds every person, people with a look first, each with their looks and row facts" do
    lookless = Person.create!(first_name: "Test", last_name: "Athlete", athlete: true, avatar_url: "https://img.example/gamma.png")
    capture_only = Person.create!(first_name: "Test", last_name: "Athlete Delta")
    capture_only.appearances.create!(descriptor: "Demo look", music_video_slug: @video.slug, performer_ordinal: 1)
    @away.update!(retired_at: Time.current)

    results = MusicVideos::RecastAthleteSearch.call("test athlete")
    assert_equal %w[test-athlete-alpha test-athlete test-athlete-delta], results.map(&:slug),
                 "a look outranks even an exact name; then the name ranking"
    assert_equal ["1 look", "0 looks", "0 looks"], results.map(&:hint)
    assert_equal [{ slug: @home.slug, descriptor: "Home Blue", default: true, image_url: nil, state: "empty", error: nil,
                    url: "/people/test-athlete-alpha/models/#{@home.slug}" }], results.first.looks
    assert_equal results.first.looks.first, results.first.default_look, "the row shows the default look"
    assert_equal [nil, nil], results.last(2).map(&:default_look), "nobody's capture look, and no look at all"
    assert_equal [[], []], results.last(2).map(&:looks), "a capture look is not one to recast into"
    assert_equal ["athlete", "athlete", nil], results.map(&:vocation)
    assert_equal [nil, "https://img.example/gamma.png", nil], results.map(&:avatar_url)
    assert_includes results.map(&:slug), lookless.slug
    assert_empty MusicVideos::RecastAthleteSearch.call("  ")
    assert_empty MusicVideos::RecastAthleteSearch.call("100%")
  end

  test "the typeahead returns at most ten, in a fixed number of queries" do
    12.times { |n| Person.create!(first_name: "Test", last_name: "Crowd #{n}", athlete: true) }
    count = ->(query) do
      seen = 0
      counter = ->(*, payload) { seen += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        ActiveRecord::Base.uncached { MusicVideos::RecastAthleteSearch.call(query) }
      end
      seen
    end

    assert_equal 10, MusicVideos::RecastAthleteSearch.call("test crowd").size
    # Like with like: a page where nobody has a look skips the character-sheet read.
    one, ten = count.call("test crowd 3"), count.call("test crowd")
    assert_operator one, :>, 0
    assert_equal one, ten, "one person or ten, the same queries"
    assert_equal one + 1, count.call("test athlete alpha"), "a page with looks reads their sheets once"
  end

  test "ten people with looks and sheets cost the same queries as one, and each row names its default look" do
    crowd = Array.new(10) do |n|
      Person.create!(first_name: "Sample", last_name: "Squad #{n}", athlete: true).tap do |person|
        first, second = %w[Home Away].map { |name| person.appearances.create!(descriptor: "#{name} #{n}") }
        [first, second].each do |look|
          sheet = Artifact.create!(kind: "character_sheet", image_url: "https://example.test/#{look.slug}.png", source: "test")
          sheet.subjects.create!(person_slug: person.slug, appearance_slug: look.slug, ordinal: 1)
        end
        second.make_default! if n.odd?
      end
    end
    count = ->(query) do
      seen = 0
      counter = ->(*, payload) { seen += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        ActiveRecord::Base.uncached { MusicVideos::RecastAthleteSearch.call(query) }
      end
      seen
    end

    results = MusicVideos::RecastAthleteSearch.call("sample squad")
    assert_equal 10, results.size
    results.each do |result|
      n = result.name[/\d+\z/].to_i
      look = crowd[n].appearances.find_by!(descriptor: "#{n.odd? ? 'Away' : 'Home'} #{n}")
      assert_equal [look.slug, look.descriptor, "https://example.test/#{look.slug}.png", "ready"],
                   result.default_look.values_at(:slug, :descriptor, :image_url, :state)
      assert_equal "2 looks", result.hint
    end
    assert_equal count.call("sample squad 3"), count.call("sample squad"), "one person or ten, the same queries"
  end

  test "a person whose default look is retired or a capture has looks counted and no default look shown" do
    @home.update!(retired_at: Time.current)

    result = MusicVideos::RecastAthleteSearch.call("test athlete alpha").sole

    assert_equal ["1 look", nil], [result.hint, result.default_look]
  end

  test "swap off then on restores the athlete and look; off reads as kept everywhere" do
    recast(@jacket, person_slug: @athlete.slug, appearance_slug: @away.slug)
    recast(@jacket, keep: true)
    @jacket.reload

    assert @jacket.swap_remembered?
    assert_not @jacket.swap?
    assert_not @jacket.recast?
    assert_not @jacket.recast_pending?
    assert_nil @jacket.swap_person
    assert_nil @jacket.swap_look
    assert @video.reload.recast_assigned?
    assert_empty @video.video_performers.select(&:swap?)
    chunk = @video.video_chunks.first
    assert(@video.video_chunks.none? { |c| c.swap_target&.swap? }, "no chunk targets a swap that is off")
    assert_nil chunk.swap_target&.swap_look, "the hand-off offers no look"

    recast(@jacket, swap: true)
    assert_equal [@athlete.slug, @away.slug, false], @jacket.reload.values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
    assert(prompts.any? { |p| p.include?("Person A (lead) -> Test Athlete Alpha, Away White") })
  end

  test "a remembered look retired while the swap was off falls back to the athlete alone, pending" do
    recast(@jacket, person_slug: @athlete.slug, appearance_slug: @away.slug)
    recast(@jacket, keep: true)
    @away.update_columns(retired_at: Time.current)

    recast(@jacket, swap: true)
    assert_equal [@athlete.slug, nil], @jacket.reload.values_at(:recast_person_slug, :recast_appearance_slug)
    assert @jacket.recast_pending?
  end

  test "turning the swap off is allowed even when the remembered look has since been retired" do
    recast(@jacket, person_slug: @athlete.slug, appearance_slug: @away.slug)
    @away.update_columns(retired_at: Time.current)

    recast(@jacket, keep: true)
    assert @jacket.reload.swap_remembered?
  end

  test "on with nothing remembered names nobody: the same row as off" do
    recast(@jacket, swap: true)
    assert_equal [nil, nil, false], @jacket.reload.values_at(:recast_person_slug, :recast_appearance_slug, :recast_keep)
    assert_not @jacket.swap?
  end
end
