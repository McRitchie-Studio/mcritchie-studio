# Alt videos (recast pipeline, piece 13): one source video (music_videos, its
# chunks cut once) yields many generated versions, each with its OWN swap set.
#
#   alt_videos               one version of a source: numbered per source, with
#                            the swaps snapshotted from the cast card as jsonb
#   alt_video_clips          alt video x chunk: the window, and the regenerate flag
#   alt_video_clip_versions  each MP4 uploaded back for a clip; the latest
#                            primary_since is the primary (exactly one per clip)
#
# video_stitches moves onto the alt video (alt_video_slug), numbered per alt video.
#
# DATA STEP (idempotent; production had 0 takes and 0 stitches at the cut):
# every source with a generated take or a stitch gets "alt video 1" with that
# source's current swaps as its snapshot, one clip per chunk window and per
# take window, every take copied as a version (same number, same object, same
# primary order), every stitch pointed at it, and its chunks' regenerate flags
# carried onto its clips. Nothing is deleted: video_chunk_takes and the
# video_clips regenerate columns stay as they were, read by nothing, for a
# later drop.
class CreateAltVideos < ActiveRecord::Migration[8.1]
  # Migration-local rows, so a later model change never rewrites this step.
  class Video < ActiveRecord::Base
    self.table_name = "music_videos"
  end

  class Performer < ActiveRecord::Base
    self.table_name = "video_performers"
  end

  class Chunk < ActiveRecord::Base
    self.table_name = "video_clips"
  end

  class Take < ActiveRecord::Base
    self.table_name = "video_chunk_takes"
  end

  class Stitch < ActiveRecord::Base
    self.table_name = "video_stitches"
  end

  class Alt < ActiveRecord::Base
    self.table_name = "alt_videos"
  end

  class Clip < ActiveRecord::Base
    self.table_name = "alt_video_clips"
  end

  class Version < ActiveRecord::Base
    self.table_name = "alt_video_clip_versions"
  end

  class PersonRow < ActiveRecord::Base
    self.table_name = "people"
  end

  class LookRow < ActiveRecord::Base
    self.table_name = "appearances"
  end

  def up
    create_table :alt_videos do |t|
      t.string :slug, null: false
      t.string :music_video_slug, null: false
      t.integer :number, null: false
      t.jsonb :swaps, null: false, default: []
      t.timestamps
      t.index :slug, unique: true
      t.index %i[music_video_slug number], unique: true
    end

    create_table :alt_video_clips do |t|
      t.string :alt_video_slug, null: false
      t.integer :chunk_ordinal, null: false
      t.integer :start_ms, null: false
      t.integer :end_ms, null: false
      t.datetime :regenerate_requested_at
      t.string :regenerate_note
      t.timestamps
      t.index %i[alt_video_slug chunk_ordinal], unique: true
    end

    create_table :alt_video_clip_versions do |t|
      t.references :alt_video_clip, null: false, foreign_key: true, index: false
      t.integer :number, null: false
      t.string :object_key, null: false
      t.bigint :byte_size, null: false
      t.string :original_filename
      t.datetime :primary_since, null: false
      t.timestamps
      t.index %i[alt_video_clip_id number], unique: true
      t.index :object_key, unique: true
    end

    add_column :video_stitches, :alt_video_slug, :string
    remove_index :video_stitches, %i[music_video_slug number]
    add_index :video_stitches, %i[alt_video_slug number], unique: true

    self.class.move_takes_and_stitches!
    change_column_null :video_stitches, :alt_video_slug, false
  end

  def down
    remove_index :video_stitches, %i[alt_video_slug number]
    remove_column :video_stitches, :alt_video_slug
    add_index :video_stitches, %i[music_video_slug number], unique: true
    drop_table :alt_video_clip_versions
    drop_table :alt_video_clips
    drop_table :alt_videos
  end

  # The data step. Safe to run again: a source that already has alt video 1
  # keeps it, a clip or version already copied is skipped.
  def self.move_takes_and_stitches!
    [Video, Performer, Chunk, Take, Stitch, Alt, Clip, Version].each(&:reset_column_information)
    slugs = (Take.distinct.pluck(:music_video_slug) + Stitch.where(alt_video_slug: nil).distinct.pluck(:music_video_slug)).uniq
    slugs.sort.each { |slug| move_one!(slug) }
  end

  def self.move_one!(slug)
    Alt.transaction do
      alt = Alt.find_by(music_video_slug: slug, number: 1) ||
            Alt.create!(slug: "#{slug}-alt-1", music_video_slug: slug, number: 1, swaps: swaps_of(slug))
      chunks = Chunk.where(music_video_slug: slug, kind: "chunk").order(:ordinal).to_a
      takes = Take.where(music_video_slug: slug).order(:chunk_ordinal, :number).to_a
      # A clip per chunk as cut now, and per take window the chunks no longer cut.
      windows = chunks.map { |c| [c.ordinal, c.start_ms, c.end_ms] }
      takes.each { |t| windows << [t.chunk_ordinal, t.start_ms, t.end_ms] unless windows.any? { |w| w[0] == t.chunk_ordinal } }
      windows.each do |ordinal, start_ms, end_ms|
        next if Clip.exists?(alt_video_slug: alt.slug, chunk_ordinal: ordinal)

        flag = chunks.find { |c| c.ordinal == ordinal && c.start_ms == start_ms && c.end_ms == end_ms }
        Clip.create!(alt_video_slug: alt.slug, chunk_ordinal: ordinal, start_ms:, end_ms:,
                     regenerate_requested_at: flag&.regenerate_requested_at, regenerate_note: flag&.regenerate_note)
      end
      takes.each do |take|
        clip = Clip.find_by!(alt_video_slug: alt.slug, chunk_ordinal: take.chunk_ordinal)
        # A take cut at a window the clip no longer has is still kept, as a version.
        next if Version.exists?(object_key: take.object_key)

        Version.create!(alt_video_clip_id: clip.id, number: take.number, object_key: take.object_key,
                        byte_size: take.byte_size, original_filename: take.original_filename,
                        primary_since: take.current_since, created_at: take.created_at, updated_at: take.updated_at)
      end
      Stitch.where(music_video_slug: slug, alt_video_slug: nil).update_all(alt_video_slug: alt.slug)
    end
  end

  # The cast card's swaps as they stand: [{ performer_ordinal, person_slug,
  # appearance_slug, person_name, look_name }], swapped people only.
  def self.swaps_of(slug)
    rows = Performer.where(music_video_slug: slug).where.not(recast_person_slug: nil)
                    .where(recast_keep: [false, nil]).order(:ordinal).to_a
    people = PersonRow.where(slug: rows.map(&:recast_person_slug)).index_by(&:slug)
    looks = LookRow.where(slug: rows.filter_map(&:recast_appearance_slug)).index_by(&:slug)
    rows.map do |p|
      person = people[p.recast_person_slug]
      look = looks[p.recast_appearance_slug]
      { "performer_ordinal" => p.ordinal, "person_slug" => p.recast_person_slug,
        "appearance_slug" => p.recast_appearance_slug.presence,
        "person_name" => person ? "#{person.first_name} #{person.last_name}".squish : p.recast_person_slug,
        "look_name" => look&.descriptor }
    end
  end
end
