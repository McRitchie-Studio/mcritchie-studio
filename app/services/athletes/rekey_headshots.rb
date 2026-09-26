# RE-FILES CACHED HEADSHOT OBJECTS UNDER THE KEY THE MODEL WOULD WRITE TODAY.
#
# WHY THIS EXISTS. On 2026-09-26 a hand-rolled backfill was run against
# production which derived the S3 folder from `person.contracts` instead of from
# the athlete's own `team_slug`. Production carries ZERO rows in `contracts` and
# ZERO in `teams`, so every lookup returned nil and all 2,043 athletes with a
# cached headshot were filed under `free-agents/` — rostered players included.
# `jaxon-smith-njigba` has `team_slug = "seattle-seahawks"` and a stored key
# reading `headshots/nfl/free-agents/jaxon-smith-njigba/400.png`.
#
# WHY IT CANNOT HEAL ITSELF. `nfl:upload_headshots` decides "already done" from
# VARIANT PRESENCE — do original/100/400 exist — and never from the key. So every
# misfiled athlete is now permanently `skipped_complete` there, and the taxonomy
# Athlete#headshot_key_prefix centralized never reaches them. The defect hides
# itself, which is why the repair reads the STORED key against the COMPUTED
# prefix rather than asking whether anything is missing.
#
# WHAT IS NOT BROKEN, so this does not try to fix it: serving. ImageCache#url is
# `Studio::S3.url(key: s3_key)` and Athlete#headshot_url reads the stored row, so
# nothing rebuilds a key from the prefix and every misfiled avatar renders today.
# This is a taxonomy defect, not an outage — so the ordering below is chosen so
# that no athlete is EVER without a servable row, not so the repair finishes fast.
#
# THE ORDER IS THE WHOLE DESIGN, per athlete:
#
#   1. COPY every stale object to its new key. Both copies now exist; the rows
#      still point at the old one, so serving is untouched.
#   2. REPOINT the rows, all of that athlete's in ONE transaction. Each row now
#      names an object written in step 1.
#   3. RETIRE the old objects, only after step 2 has committed, and only for a
#      key no ImageCache row still references.
#
# A failure in step 1 leaves the rows untouched. A failure in step 2 rolls the
# whole athlete back. A failure in step 3 leaves an inert duplicate object and
# nothing else. There is no ordering here in which an athlete loses their avatar,
# and deleting first — the obvious cheap version — is exactly the ordering that
# would, because until step 1 lands the old object is the ONLY copy.
#
# IDEMPOTENT, and cheap on a re-run: an athlete whose rows already match the
# computed prefix is counted and skipped without a single S3 call, and a partly
# copied athlete re-uses the objects step 1 already wrote (`exists?`) instead of
# paying for the bytes twice.
#
# Usage:
#   Athletes::RekeyHeadshots.new.call                      # repair, delete orphans
#   Athletes::RekeyHeadshots.new(limit: 25).call            # one inspectable wave
#   Athletes::RekeyHeadshots.new(delete_orphans: false).call # leave the old objects
class Athletes::RekeyHeadshots
  PURPOSE = "headshot"

  # MIRRORS Studio::ImageCache.cache!'s own header so a re-filed object keeps the
  # caching contract a freshly uploaded one gets. Restated rather than read from
  # the engine because the engine spells it inline at the `upload` call site and
  # exposes no constant to borrow; if that string changes there, change it here.
  CACHE_CONTROL = "public, max-age=31536000, immutable".freeze

  attr_reader :stats

  def initialize(limit: nil, delete_orphans: true, verbose: false)
    @limit = limit
    @delete_orphans = delete_orphans
    @verbose = verbose
    @stats = Hash.new(0)
  end

  def call
    puts "candidates: #{candidates.count} athletes with a cached headshot; " \
         "delete orphans: #{@delete_orphans}#{@limit ? "; limit: #{@limit} athlete(s)" : ""}"

    candidates.find_each do |athlete|
      # BOUNDED BEFORE THE COUNTER, exactly as nfl:upload_headshots bounds its
      # waves: an athlete the limit stopped us reaching was never `considered`,
      # so `unattempted` cannot read a bounded wave as work declined.
      break if @limit && (@stats[:rekeyed] + @stats[:failed]) >= @limit

      @stats[:considered] += 1
      rekey(athlete)
    end

    puts "\nstats: #{@stats.inspect}"
    @stats
  end

  # The athletes this can possibly repair: the ones that OWN headshot rows. Note
  # what it does NOT filter on — `espn_id`. That column gates
  # `nfl:upload_headshots` because an upload needs a source URL to fetch; a re-key
  # moves bytes that are already in the bucket, so an athlete whose espn_id was
  # cleared after their headshot was cached is still repairable here.
  def candidates
    Athlete.where(id: ImageCache.where(owner_type: "Athlete", purpose: PURPOSE).select(:owner_id))
           .includes(:image_caches)
  end

  # Whether a stored row disagrees with the prefix the model would write today.
  # Compares the key's DIRECTORY to the prefix rather than asking `start_with?`,
  # so a key nested one level deeper than the prefix reads as misfiled instead of
  # as a match.
  def self.misfiled?(row, prefix)
    File.dirname(row.s3_key.to_s) != prefix
  end

  private

  def rekey(athlete)
    prefix = athlete.headshot_key_prefix
    rows = athlete.image_caches.select { |row| row.purpose == PURPOSE }
    stale = rows.select { |row| self.class.misfiled?(row, prefix) }

    if stale.empty?
      @stats[:already_filed] += 1
      return
    end

    # OLD KEY CAPTURED NOW, before the repoint, because step 3 needs it and the
    # row will not be able to answer for it afterwards.
    moves = stale.map { |row| [row, row.s3_key, "#{prefix}/#{File.basename(row.s3_key)}"] }

    begin
      moves.each { |row, old_key, new_key| copy_object(row, old_key, new_key) }
      ActiveRecord::Base.transaction do
        moves.each { |row, _old_key, new_key| row.update!(s3_key: new_key) }
      end
      @stats[:rekeyed] += 1
      puts "  [+] #{athlete.person_slug.ljust(28)} -> #{prefix}/ (#{moves.size} object(s))" if @verbose || @stats[:rekeyed] <= 5 || (@stats[:rekeyed] % 50).zero?
    rescue => e
      # COUNTED AND CARRIED ON. One unreadable object must not cost the other
      # two thousand their re-key, and this athlete's rows were left pointing at
      # objects that still exist, so the cost of the failure is a stale folder
      # name and nothing else.
      @stats[:failed] += 1
      puts "  [!] #{athlete.person_slug}: #{e.class}: #{e.message}"
      return
    end

    # OUTSIDE THE RESCUE ABOVE ON PURPOSE. The re-key is done and recorded; a
    # failure to tidy up after it is not a failed re-key, and counting it as one
    # would make `failed > rekeyed` fire over litter.
    retire_orphans(moves) if @delete_orphans
  end

  def copy_object(row, old_key, new_key)
    if Studio::S3.exists?(key: new_key)
      # A PREVIOUS WAVE ALREADY WROTE IT — it got as far as step 1 and no
      # further. Re-fetching the bytes would be correct and wasteful; 6,129
      # objects is enough traffic to make the head request worth it.
      @stats[:objects_already_present] += 1
      return
    end

    Studio::S3.upload(
      key: new_key,
      body: Studio::S3.download(key: old_key),
      content_type: row.content_type.presence || "image/png",
      cache_control: CACHE_CONTROL
    )
    @stats[:objects_copied] += 1
  end

  def retire_orphans(moves)
    moves.each do |_row, old_key, _new_key|
      # A ROW STILL POINTING AT IT IS A VETO. Nothing should hold the old key by
      # now — the repoint has committed and `s3_key` is uniquely indexed — so
      # this asks the database rather than trusting the argument that it cannot
      # happen. The whole risk in this repair is deleting a live object.
      if ImageCache.exists?(s3_key: old_key)
        @stats[:orphans_held] += 1
        next
      end

      begin
        Studio::S3.delete(key: old_key)
        @stats[:orphans_deleted] += 1
      rescue => e
        # AN UNDELETED ORPHAN IS INERT: no row references it, so it serves
        # nothing and costs storage. Reported, never fatal.
        @stats[:orphans_failed] += 1
        puts "  [!] orphan #{old_key}: #{e.class}: #{e.message}"
      end
    end
  end
end
