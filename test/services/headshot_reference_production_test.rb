require "test_helper"
require "rake"
require "aws-sdk-s3"

# [unit][integration] NFL HEADSHOTS REFERENCE PRODUCTION'S COPY OFF PRODUCTION.
#
# The hub's headshot seeders call Studio::ImageCache.reference_or_cache!
# (studio-engine 0.103.0). Outside production, with Studio.s3_production_public_url
# set, it HEADs "<prefix>-production" read-only and records a stored_in
# "production" row when production holds the key; it uploads to the own bucket
# only when production does not. In production it is cache!.
#
# THE S3 CLIENT IS AN SDK STUB, NOT A STUBBED HELPER. Aws::S3::Client with
# stub_responses answers head_object and put_object from this file, and every
# request it served is read back off `api_requests`. So the integration cases run
# the engine's real reference_or_cache! and upload path across the I/O boundary,
# and assert the BUCKET each request went to — the only thing that separates "read
# production" from "wrote production". No request leaves the process.
#
# THE SUITE LEAVES s3_production_public_url NIL (config/initializers/studio.rb),
# which is what keeps every other test from sending a live HEAD. These cases set it
# and restore it.
class HeadshotReferenceProductionTest < ActiveSupport::TestCase
  PRODUCTION_HOST = "https://assets.mcritchie.studio".freeze

  # A valid 1x1 PNG: the upload path resizes it with ImageMagick, so it must decode.
  PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  setup do
    @production_url_was = Studio.s3_production_public_url
    Studio.s3_production_public_url = PRODUCTION_HOST
  end

  teardown do
    Studio.s3_production_public_url = @production_url_was
  end

  test "the suite boots with production references off, so no test sends a live HEAD" do
    Studio.s3_production_public_url = @production_url_was

    assert_nil Studio.s3_production_public_url,
               "config/initializers/studio.rb must leave the knob nil under the test suite"
    refute Studio::S3.production_references?
  end

  # --- Nflverse::SeedPlayers, across the stubbed client ----------------------

  test "the seeder references production's copy when production holds every variant" do
    athlete = headshot_athlete
    prefix = athlete.headshot_key_prefix
    client = stub_client(production_keys: variant_keys(prefix))

    run_seeder(athlete, client)

    rows = athlete.image_caches.reload.select { |row| row.purpose == "headshot" }
    assert_equal %w[100 400 original], rows.map(&:variant).sort
    assert rows.all?(&:production_reference?), "every variant production holds is recorded as a reference"
    assert_empty requests(client, :put_object), "a reference uploads nothing, to any bucket"
    assert_equal [production_bucket], requests(client, :head_object).map { |r| r[:bucket] }.uniq,
                 "the only question asked is a read-only HEAD of production's bucket"
    assert_equal "#{PRODUCTION_HOST}/#{prefix}/400.png", athlete.headshot_url(width: 400),
                 "a reference serves from production's host"
  end

  test "the seeder uploads to its own bucket when production lacks the key" do
    athlete = headshot_athlete
    client = stub_client(production_keys: [])

    run_seeder(athlete, client)

    rows = athlete.image_caches.reload.select { |row| row.purpose == "headshot" }
    assert_equal %w[100 400 original], rows.map(&:variant).sort
    refute rows.any?(&:production_reference?), "an uploaded variant is the own bucket's"
    puts_ = requests(client, :put_object)
    assert_equal 3, puts_.size
    assert_equal [Studio::S3.bucket], puts_.map { |r| r[:bucket] }.uniq
    refute_equal production_bucket, Studio::S3.bucket, "the own bucket off production is not production's"
  end

  test "a variant production holds is referenced and only the missing one is uploaded" do
    athlete = headshot_athlete
    prefix = athlete.headshot_key_prefix
    client = stub_client(production_keys: variant_keys(prefix) - ["#{prefix}/400.png"])

    run_seeder(athlete, client)

    rows = athlete.image_caches.reload.index_by(&:variant)
    assert rows["original"].production_reference?
    assert rows["100"].production_reference?
    refute rows["400"].production_reference?
    assert_equal [Studio::S3.full_key("#{prefix}/400.png")], requests(client, :put_object).map { |r| r[:key] }
  end

  # PRODUCTION BEHAVIOUR IS UNCHANGED: there reference_or_cache! IS cache!, so the
  # knob being set changes nothing. No HEAD is sent and every variant is uploaded.
  test "in production the seeder uploads exactly as cache! did and sends no HEAD" do
    athlete = headshot_athlete
    client = stub_client(production_keys: variant_keys(athlete.headshot_key_prefix))

    Studio::S3.stub(:production_environment?, true) { run_seeder(athlete, client) }

    rows = athlete.image_caches.reload.select { |row| row.purpose == "headshot" }
    assert_equal 3, rows.size
    refute rows.any?(&:production_reference?)
    assert_empty requests(client, :head_object), "production never asks whether production has it"
    assert_equal 3, requests(client, :put_object).size
  end

  test "a HEAD that fails for any reason but not-found is a failure, never a quiet upload" do
    athlete = headshot_athlete
    client = Aws::S3::Client.new(stub_responses: true)
    client.stub_responses(:head_object, "Forbidden")

    seeder = run_seeder(athlete, client)

    assert_equal 1, seeder.stats[:headshots_failed]
    assert_empty requests(client, :put_object), "a token that cannot read production must not copy everything"
    assert_empty athlete.image_caches.reload
  end

  # --- the other seeders call the reference path ---------------------------

  test "nfl:upload_headshots seeds through reference_or_cache!" do
    athlete = headshot_athlete
    Athlete.where.not(id: athlete.id).update_all(espn_id: nil)

    called = []
    with_rake("nfl:upload_headshots", "HEADSHOT_PAUSE" => "0") do
      Studio::ImageCache.stub(:cache!, ->(**) { flunk "the seeder must ask reference_or_cache!, not cache!" }) do
        Studio::ImageCache.stub(:reference_or_cache!, ->(owner:, **) { called << owner; {} }) do
          capture_io { Rake::Task["nfl:upload_headshots"].invoke }
        end
      end
    end

    assert_equal [athlete], called
  end

  test "nfl:upload_coach_headshots references a first upload and re-uploads a refresh" do
    Coach.update_all(espn_headshot_url: nil)
    fresh = Coach.first
    person = Person.create!(first_name: "Refresh", last_name: "Coach#{SecureRandom.hex(3)}")
    role = (Coach::ROLES - [fresh.role]).first
    refreshed = Coach.create!(person_slug: person.slug, team_slug: fresh.team_slug, role: role, sport: "football")
    fresh.update!(espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/coaches/full/1.png")
    refreshed.update!(espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/coaches/full/2-new.png")
    ImageCache.create!(owner: refreshed, purpose: "headshot", variant: "original",
                       s3_key: "headshots/nfl/coaches/#{refreshed.slug}/original.png",
                       source_url: "https://a.espncdn.com/i/headshots/nfl/coaches/full/2-old.png")

    calls = []
    with_rake("nfl:upload_coach_headshots") do
      Studio::ImageCache.stub(:cache!, ->(owner:, **) { calls << [:cache!, owner]; {} }) do
        Studio::ImageCache.stub(:reference_or_cache!, ->(owner:, **) { calls << [:reference_or_cache!, owner]; {} }) do
          capture_io { Rake::Task["nfl:upload_coach_headshots"].invoke }
        end
      end
    end

    assert_includes calls, [:reference_or_cache!, fresh]
    assert_includes calls, [:cache!, refreshed],
                    "production's object under a refreshed coach's key may be the old photo"
  end

  private

  def headshot_athlete
    person = Person.create!(first_name: "Ref", last_name: "Erence#{SecureRandom.hex(3)}", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", team_slug: "buffalo-bills",
                    espn_id: "99#{rand(10_000..99_999)}",
                    espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/players/full/1.png")
  end

  def variant_keys(prefix) = %w[original 100 400].map { |v| "#{prefix}/#{v}.png" }

  def production_bucket = "#{Studio.s3_bucket_prefix}-production"

  # head_object answers 200 for a key production holds and the SDK's NotFound for
  # any other, which is what R2 answers the dev token (measured 2026-10-10).
  def stub_client(production_keys:)
    held = production_keys.map { |key| Studio::S3.full_key(key) }
    client = Aws::S3::Client.new(stub_responses: true)
    client.stub_responses(:head_object, lambda do |context|
      if context.params[:bucket] == production_bucket && held.include?(context.params[:key])
        { content_length: 42, content_type: "image/png" }
      else
        "NotFound"
      end
    end)
    client
  end

  def requests(client, operation)
    client.api_requests.select { |r| r[:operation_name] == operation }.map { |r| r[:params] }
  end

  # The seeder's own #cache_headshot, as athlete_test drives it, with the source
  # fetch and its SSRF lookup replaced: nothing here talks to ESPN or DNS.
  def run_seeder(athlete, client)
    seeder = Nflverse::SeedPlayers.new(csv_body: "", upload_headshots: false)
    Studio::S3.stub(:client, client) do
      Studio::ImageCache.stub(:validate_source_url!, ->(*) { }) do
        Studio::ImageCache.stub(:fetch_remote, ->(*) { PNG.dup }) do
          seeder.send(:cache_headshot, athlete)
        end
      end
    end
    seeder
  end

  def with_rake(name, env = {})
    Rails.application.load_tasks unless Rake::Task.task_defined?(name)
    Rake::Task[name].reenable
    was = ENV.to_h.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    env.each_key { |k| ENV.delete(k) }
    was&.each { |k, v| ENV[k] = v }
  end
end
