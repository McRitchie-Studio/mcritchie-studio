require "test_helper"

# [unit] THE REPAIR FOR 2,043 MISFILED HEADSHOTS, and specifically for the one
# property that matters more than the repair: no athlete is ever without a
# servable row, in any ordering, including a failed one.
#
# S3 is a FAKE BUCKET here — a Hash plus a call log — for two reasons. The first is
# the ordinary one: no network, no credentials. The second is the point of the
# file: the service's correctness IS its ordering (copy, repoint, retire), and an
# ordering is only observable from inside the calls. So every stub records the
# state of the DATABASE at the moment S3 was touched, which turns "writes before
# it repoints" and "deletes only after it has repointed" into assertions rather
# than a reading of the source.
class Athletes::RekeyHeadshotsTest < ActiveSupport::TestCase
  # --- the motivating case -------------------------------------------------

  # THE DEFECT ITSELF, as measured on production 2026-09-26. A hand-rolled
  # backfill derived the folder from `person.contracts` — an EMPTY table — so a
  # rostered Seahawk was filed under `free-agents/`. The repair has to move him to
  # the folder Athlete#headshot_key_prefix names from his own team_slug.
  test "re-files a rostered athlete out of free-agents and under their team" do
    athlete = misfiled_athlete(team_slug: "seattle-seahawks")
    bucket = FakeBucket.new(athlete.image_caches.map { |row| [row.s3_key, "png-bytes-#{row.variant}"] }.to_h)

    stats = nil
    bucket.install { capture_io { stats = Athletes::RekeyHeadshots.new.call } }

    assert_equal 1, stats[:rekeyed]
    assert_equal 3, stats[:objects_copied]
    keys = athlete.image_caches.reload.map(&:s3_key).sort
    assert_equal ["headshots/nfl/seattle-seahawks/#{athlete.person_slug}/100.png",
                  "headshots/nfl/seattle-seahawks/#{athlete.person_slug}/400.png",
                  "headshots/nfl/seattle-seahawks/#{athlete.person_slug}/original.png"], keys
    assert keys.all? { |key| bucket.objects.key?(key) },
           "every repointed row must name an object that exists — the row is what serves the avatar"
  end

  # THE BASENAME CARRIES THE VARIANT AND THE EXTENSION, and the new key is built
  # from it rather than from a rebuilt "#{variant}.png". A jpg object re-keyed as
  # .png would be a row pointing at nothing, which is the one outcome worse than a
  # wrong folder.
  test "preserves the object's own extension" do
    athlete = misfiled_athlete(team_slug: "buffalo-bills", ext: "jpg", content_type: "image/jpeg")
    bucket = FakeBucket.new(athlete.image_caches.map { |row| [row.s3_key, "jpg"] }.to_h)

    bucket.install { capture_io { Athletes::RekeyHeadshots.new.call } }

    assert_equal ["headshots/nfl/buffalo-bills/#{athlete.person_slug}/100.jpg",
                  "headshots/nfl/buffalo-bills/#{athlete.person_slug}/400.jpg",
                  "headshots/nfl/buffalo-bills/#{athlete.person_slug}/original.jpg"],
                 athlete.image_caches.reload.map(&:s3_key).sort
    assert_equal ["image/jpeg"], bucket.uploads.map { |u| u[:content_type] }.uniq,
                 "a re-filed object keeps the content type the row records"
  end

  # --- the ordering, which is the whole design -----------------------------

  # WRITE FIRST. At the moment the new object is uploaded the row must still point
  # at the OLD key: both copies then exist, and serving is untouched. The inverse
  # ordering (repoint, then copy) is the one that puts a row in front of an object
  # that is not there yet.
  test "uploads the new object while the row still points at the old one" do
    athlete = misfiled_athlete(team_slug: "buffalo-bills")
    row = athlete.image_caches.find { |c| c.variant == "400" }
    old_key = row.s3_key
    bucket = FakeBucket.new(athlete.image_caches.map { |c| [c.s3_key, "b"] }.to_h, watch: row)

    bucket.install { capture_io { Athletes::RekeyHeadshots.new.call } }

    upload = bucket.log.find { |entry| entry[0] == :upload && entry[1].end_with?("/400.png") }
    assert upload, "the 400 variant should have been copied"
    assert_equal old_key, upload[2],
                 "at upload time the row must still serve the old object — writing after the " \
                 "repoint would leave the row naming an object that does not exist yet"
  end

  # DELETE LAST, AND ONLY AFTER THE REPOINT. The old object is the ONLY copy until
  # the new one is written, and the only SERVED copy until the row moves, so its
  # deletion is the last act and its precondition is the row already pointing
  # somewhere else.
  test "deletes the old object only after the row points at the new one" do
    athlete = misfiled_athlete(team_slug: "buffalo-bills")
    row = athlete.image_caches.find { |c| c.variant == "400" }
    old_key = row.s3_key
    new_key = "headshots/nfl/buffalo-bills/#{athlete.person_slug}/400.png"
    bucket = FakeBucket.new(athlete.image_caches.map { |c| [c.s3_key, "b"] }.to_h, watch: row)

    bucket.install { capture_io { Athletes::RekeyHeadshots.new.call } }

    delete = bucket.log.find { |entry| entry[0] == :delete && entry[1] == old_key }
    assert delete, "the orphaned object should have been retired"
    assert_equal new_key, delete[2],
                 "the row must already serve the new object before the old one is destroyed"
    assert_operator bucket.log.index { |e| e[0] == :upload && e[1] == new_key },
                    :<,
                    bucket.log.index { |e| e[0] == :delete && e[1] == old_key },
                    "the copy has to precede the delete — the old object is the only copy until it does"
    refute bucket.objects.key?(old_key), "the orphan is gone"
    assert bucket.objects.key?(new_key), "and the object the row names is there"
  end

  # THE FAILURE PATH IS THE REAL TEST. A copy that dies partway must leave the
  # athlete exactly as they were: three rows, each naming an object that exists.
  # This is the case a "delete then re-upload" repair gets wrong.
  test "a failed copy leaves every row pointing at an object that still exists" do
    athlete = misfiled_athlete(team_slug: "buffalo-bills")
    before = athlete.image_caches.map(&:s3_key).sort
    bucket = FakeBucket.new(athlete.image_caches.map { |c| [c.s3_key, "b"] }.to_h)
    bucket.fail_upload_matching(/\/400\.png\z/)

    stats = nil
    bucket.install { capture_io { stats = Athletes::RekeyHeadshots.new.call } }

    assert_equal 1, stats[:failed]
    assert_equal 0, stats[:rekeyed]
    assert_equal before, athlete.image_caches.reload.map(&:s3_key).sort,
                 "a half-copied athlete keeps every row it had — the rows are what serve the avatar"
    assert before.all? { |key| bucket.objects.key?(key) },
           "and nothing it still points at was deleted"
    assert_empty bucket.log.select { |entry| entry[0] == :delete },
                 "a failed re-key deletes nothing at all"
  end

  # ONE TRANSACTION PER ATHLETE, so a repoint that cannot finish moves NONE of that
  # athlete's rows. Without it the 400 variant's failure would leave `original` and
  # `100` under the new folder and `400` under the old one — an athlete split across
  # two folders, which still serves but is a second, subtler version of the defect
  # being repaired.
  #
  # THE CONFLICT IS REAL, NOT STUBBED: `s3_key` is uniquely indexed, so an
  # unrelated row already holding the target key makes `update!` raise for that
  # variant and that variant only. The squatter is owner-less and carries a
  # different purpose, so it is not itself a candidate and cannot perturb the run.
  test "a repoint that cannot complete moves none of the athlete's rows" do
    athlete = misfiled_athlete(team_slug: "buffalo-bills")
    before = athlete.image_caches.map(&:s3_key).sort
    ImageCache.create!(owner: nil, purpose: "roster_photo", variant: "400",
                       s3_key: "headshots/nfl/buffalo-bills/#{athlete.person_slug}/400.png",
                       content_type: "image/png")
    bucket = FakeBucket.new(before.index_with { "b" })

    stats = nil
    bucket.install { capture_io { stats = Athletes::RekeyHeadshots.new.call } }

    assert_equal 1, stats[:failed]
    assert_equal 0, stats[:rekeyed]
    assert_equal before, athlete.image_caches.reload.map(&:s3_key).sort,
                 "all three rows roll back together — an athlete half-moved between two " \
                 "folders is the defect this task exists to remove"
    assert_empty bucket.log.select { |entry| entry[0] == :delete },
                 "and a rolled-back athlete loses no object"
  end

  # --- what it must NOT touch ---------------------------------------------

  # `free-agents/` IS A LEGITIMATE FOLDER, for an athlete who genuinely has no
  # team. The repair keys off the key-versus-prefix comparison, not off the string
  # "free-agents", so a real free agent is left alone. Over-correcting here would
  # churn every unrostered athlete on every run.
  test "leaves a genuinely teamless athlete under free-agents" do
    athlete = misfiled_athlete(team_slug: nil)
    assert_equal "headshots/nfl/free-agents/#{athlete.person_slug}", athlete.headshot_key_prefix,
                 "precondition: free-agents IS this athlete's correct folder"
    bucket = FakeBucket.new(athlete.image_caches.map { |c| [c.s3_key, "b"] }.to_h)

    stats = nil
    bucket.install { capture_io { stats = Athletes::RekeyHeadshots.new.call } }

    assert_equal 1, stats[:already_filed]
    assert_equal 0, stats[:rekeyed]
    assert_empty bucket.log, "a correctly filed athlete costs ZERO S3 calls, not three head requests"
  end

  # IDEMPOTENT AND CHEAP ON THE SECOND PASS. A wave that got as far as writing the
  # object and no further must not pay for the bytes again.
  test "re-uses an object a previous wave already copied" do
    athlete = misfiled_athlete(team_slug: "buffalo-bills")
    objects = athlete.image_caches.map { |c| [c.s3_key, "b"] }.to_h
    objects["headshots/nfl/buffalo-bills/#{athlete.person_slug}/400.png"] = "already-there"
    bucket = FakeBucket.new(objects)

    stats = nil
    bucket.install { capture_io { stats = Athletes::RekeyHeadshots.new.call } }

    assert_equal 1, stats[:objects_already_present]
    assert_equal 2, stats[:objects_copied]
    assert_empty bucket.log.select { |entry| entry[0] == :download && entry[1].end_with?("/400.png") },
                 "the bytes already in the bucket are not fetched a second time"
    assert_equal "already-there", bucket.objects["headshots/nfl/buffalo-bills/#{athlete.person_slug}/400.png"],
                 "and the object that was there is not overwritten"
  end

  # THE OPT-OUT, for an operator who wants to eyeball the result before anything
  # is destroyed. The rows still move; only the cleanup is withheld.
  test "delete_orphans false repoints the rows and keeps the old objects" do
    athlete = misfiled_athlete(team_slug: "buffalo-bills")
    old_keys = athlete.image_caches.map(&:s3_key)
    bucket = FakeBucket.new(old_keys.index_with { "b" })

    stats = nil
    bucket.install { capture_io { stats = Athletes::RekeyHeadshots.new(delete_orphans: false).call } }

    assert_equal 1, stats[:rekeyed]
    assert_equal 0, stats[:orphans_deleted]
    assert old_keys.all? { |key| bucket.objects.key?(key) }, "every old object is still there"
    assert athlete.image_caches.reload.none? { |c| old_keys.include?(c.s3_key) },
           "and no row still points at one"
  end

  # THE SAFETY CATCH, FORCED. In normal operation this branch cannot be reached:
  # `s3_key` is uniquely indexed, so once the repoint commits nothing holds the old
  # key. The condition is therefore STUBBED, which is honest about what the test
  # proves — not that the branch fires in production, but that its CONSEQUENCE is
  # the safe one: a key some row still references is never deleted, and the run
  # says so instead of silently skipping.
  test "refuses to delete an object an ImageCache row still references" do
    athlete = misfiled_athlete(team_slug: "buffalo-bills")
    old_keys = athlete.image_caches.map(&:s3_key)
    bucket = FakeBucket.new(old_keys.index_with { "b" })

    stats = nil
    bucket.install do
      ImageCache.stub(:exists?, ->(*) { true }) do
        capture_io { stats = Athletes::RekeyHeadshots.new.call }
      end
    end

    assert_equal 3, stats[:orphans_held]
    assert_equal 0, stats[:orphans_deleted]
    assert old_keys.all? { |key| bucket.objects.key?(key) }, "nothing was deleted"
  end

  # --- bounding the run ----------------------------------------------------

  # WAVES, for the same reason the uploader has them: ~2,000 athletes is more S3
  # traffic than an operator wants to start blind. The limit bounds the ATHLETES
  # moved, which is the cost being bounded.
  test "the limit stops the run after N re-keyed athletes" do
    3.times { |i| misfiled_athlete(team_slug: "buffalo-bills", suffix: 40 + i) }
    bucket = FakeBucket.new(ImageCache.where(purpose: "headshot").pluck(:s3_key).index_with { "b" })

    stats = nil
    bucket.install { capture_io { stats = Athletes::RekeyHeadshots.new(limit: 2).call } }

    assert_equal 2, stats[:rekeyed], "the limit bounds the athletes moved"
    assert_equal 2, stats[:considered],
                 "an athlete the limit stopped us reaching was never considered, so a bounded " \
                 "wave cannot read as work the run declined"
  end

  # --- the predicate the uploader borrows ----------------------------------

  # WHY dirname EQUALITY AND NOT start_with?. A key nested one level below the
  # prefix — which is what a folder-per-variant writer would produce — starts with
  # the prefix and is still misfiled. The uploader's drift counter calls this same
  # predicate, so the comparison lives in one place.
  test "a key nested below the prefix reads as misfiled" do
    prefix = "headshots/nfl/buffalo-bills/josh-allen"
    deeper = ImageCache.new(s3_key: "#{prefix}/400/original.png")

    assert Athletes::RekeyHeadshots.misfiled?(deeper, prefix)
    refute Athletes::RekeyHeadshots.misfiled?(ImageCache.new(s3_key: "#{prefix}/400.png"), prefix)
    assert Athletes::RekeyHeadshots.misfiled?(
      ImageCache.new(s3_key: "headshots/nfl/free-agents/josh-allen/400.png"), prefix
    )
  end

  private

  # An athlete whose rows are filed under `free-agents/` whatever their team_slug
  # says — the production shape after the hand-rolled backfill. With team_slug nil
  # the same rows are CORRECT, which is how the no-op case is built from the same
  # helper.
  def misfiled_athlete(team_slug:, suffix: 1, ext: "png", content_type: "image/png")
    person = Person.create!(first_name: "Re", last_name: "Key#{suffix}", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", team_slug: team_slug,
                              espn_id: "7#{suffix}",
                              espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/players/full/7#{suffix}.png")
    %w[original 100 400].each do |variant|
      ImageCache.create!(owner: athlete, purpose: "headshot", variant: variant,
                         s3_key: "headshots/nfl/free-agents/#{athlete.person_slug}/#{variant}.#{ext}",
                         content_type: content_type)
    end
    athlete.reload
  end

  # A BUCKET THAT REMEMBERS WHEN IT WAS TOUCHED. Every entry is
  # [action, key, watched_row_key_at_that_moment], so the DB state at each S3 call
  # is recoverable and the ordering can be asserted instead of read.
  class FakeBucket
    attr_reader :objects, :log, :uploads

    def initialize(objects = {}, watch: nil)
      @objects = objects
      @watch = watch
      @log = []
      @uploads = []
      @fail_upload = nil
    end

    def fail_upload_matching(pattern)
      @fail_upload = pattern
    end

    def install(&block)
      Studio::S3.stub(:exists?, ->(key:) { note(:exists, key); @objects.key?(key) }) do
        Studio::S3.stub(:download, ->(key:) { note(:download, key); @objects.fetch(key) }) do
          Studio::S3.stub(:upload, method(:fake_upload)) do
            Studio::S3.stub(:delete, ->(key:) { note(:delete, key); @objects.delete(key); nil }, &block)
          end
        end
      end
    end

    private

    def fake_upload(key:, body:, content_type: nil, cache_control: nil)
      note(:upload, key)
      raise Aws::Errors::MissingCredentialsError, "no creds" if @fail_upload && key.match?(@fail_upload)

      @uploads << { key: key, content_type: content_type, cache_control: cache_control }
      @objects[key] = body
      key
    end

    # The watched row is re-read from the DATABASE, not from the in-memory object,
    # so the log records what an avatar request would have resolved at that instant.
    def note(action, key)
      @log << [action, key, @watch && ImageCache.where(id: @watch.id).pick(:s3_key)]
    end
  end
end
