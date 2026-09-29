require "test_helper"
require "rake"

# [integration] `s3_urls:rewrite` over real rows: the dry run changes nothing, APPLY=1
# rewrites every covered column, a re-run is a no-op, and non-S3 URLs stay put.
class S3UrlsRakeTest < ActiveSupport::TestCase
  BASE = "https://assets.mcritchie.studio".freeze
  PATH_STYLE = "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production".freeze
  VHOST = "https://mcritchie-studio-production.s3.us-east-2.amazonaws.com".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("s3_urls:rewrite")
    @pikachu = Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", generation: 1,
                               sprite_url: "#{PATH_STYLE}/pokemon/25-pikachu-sprite.png",
                               avatar_url: "#{PATH_STYLE}/pokemon/25-pikachu-cropped.png",
                               shiny_female_sprite_url: "#{PATH_STYLE}/pokemon/25-pikachu-shiny-female-sprite.png",
                               avatar_fallback_url: "https://raw.githubusercontent.com/PokeAPI/sprites/x.png")
    @event = TaskEvent.create!(task_slug: "s3-rewrite-fixture", to_stage: "building", occurred_at: Time.current,
                               metadata: { "mascot" => { "slug" => "pikachu", "avatar" => "#{PATH_STYLE}/pokemon/25-pikachu-cropped.png" },
                                           "note" => "#{PATH_STYLE}/pokemon/history.png" })
    @plain_event = TaskEvent.create!(task_slug: "s3-rewrite-fixture", to_stage: "designed", occurred_at: Time.current,
                                     metadata: { "mascot" => { "slug" => "eevee", "avatar" => "/fallback.png" } })
    @sheet = Artifact.create!(kind: "character_sheet", image_url: "#{VHOST}/character-sheets/sheet.png")
    @external = Artifact.create!(kind: "character_sheet",
                                 image_url: "https://ca-times.brightspotcdn.com/dims4/x?url=#{CGI.escape(VHOST)}%2Fa.png")
  end

  def run_rake(apply: false, base: BASE)
    ENV["APPLY"] = apply ? "1" : nil
    task = Rake::Task["s3_urls:rewrite"]
    task.reenable
    capture_io { task.invoke(base) }.first
  ensure
    ENV.delete("APPLY")
  end

  def snapshot
    [@pikachu.reload.attributes, @event.reload.metadata, @plain_event.reload.metadata,
     @sheet.reload.image_url, @external.reload.image_url]
  end

  test "dry run reports counts per column and writes nothing" do
    before = snapshot
    out = run_rake

    assert_equal before, snapshot
    assert_match(/DRY RUN/, out)
    assert_match(/pokemons\.sprite_url\s+1\b/, out)
    assert_match(/pokemons\.avatar_fallback_url\s+0\b/, out)
    assert_match(/task_events\.metadata->mascot->avatar\s+1\b/, out)
    assert_match(/artifacts\.image_url\s+1\b/, out)
  end

  test "APPLY=1 rewrites every covered column; a re-run is a no-op" do
    out = run_rake(apply: true)
    assert_match(/APPLIED/, out)

    @pikachu.reload
    assert_equal "#{BASE}/pokemon/25-pikachu-sprite.png", @pikachu.sprite_url
    assert_equal "#{BASE}/pokemon/25-pikachu-cropped.png", @pikachu.avatar_url
    assert_equal "#{BASE}/pokemon/25-pikachu-shiny-female-sprite.png", @pikachu.shiny_female_sprite_url
    assert_equal "https://raw.githubusercontent.com/PokeAPI/sprites/x.png", @pikachu.avatar_fallback_url

    meta = @event.reload.metadata
    assert_equal "#{BASE}/pokemon/25-pikachu-cropped.png", meta.dig("mascot", "avatar")
    assert_equal "pikachu", meta.dig("mascot", "slug"), "the rest of the snapshot survives"
    assert_equal "#{PATH_STYLE}/pokemon/history.png", meta["note"], "only the mascot avatar is rewritten"
    assert_equal "/fallback.png", @plain_event.reload.metadata.dig("mascot", "avatar")

    assert_equal "#{BASE}/character-sheets/sheet.png", @sheet.reload.image_url
    assert_match(/brightspotcdn/, @external.reload.image_url)

    after = snapshot
    rerun = run_rake(apply: true)
    assert_equal after, snapshot
    assert_match(/pokemons\.sprite_url\s+0\b/, rerun)
    assert_match(/task_events\.metadata->mascot->avatar\s+0\b/, rerun)
  end

  test "a missing base aborts before touching anything" do
    before = snapshot
    assert_raises(ArgumentError) { run_rake(apply: true, base: nil) }
    assert_equal before, snapshot
  end
end
