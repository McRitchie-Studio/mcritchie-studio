# frozen_string_literal: true

# MUSIC VIDEOS BECOME VIDEOS (task music-videos-become-videos): the source-video
# table is `videos` now, so a movie scene or a cinematic video is not filed under
# "music". `kind` (music_video, cinematic, movie_scene) keeps saying what a row is;
# no row's value changes. R2 object keys (music_videos/...) are not touched.
#
#   music_videos                -> videos         (indexes, sequence, CHECK renamed)
#   music_video_artists         -> video_artists
#   *.music_video_slug          -> video_slug on the seven tables that point at a video
#   "MusicVideo" polymorphic    -> "Video" (none on production 2026-10-11; kept for any written since)
#
# Every statement is a catalog change: RENAME takes an ACCESS EXCLUSIVE lock for a
# moment and rewrites no row; the polymorphic UPDATEs touch rows that name the old
# class only. A statement that waits five seconds for a lock fails the migration,
# which rolls back whole; run it again.
#
# THE OLD-CODE WINDOW. Heroku's release phase runs this before the new dynos boot,
# so the old release serves for a few seconds against the new schema. Two views
# keep the renamed TABLES answering under their old names: a simple view is
# automatically updatable in Postgres, so old code reads and writes through them.
# The renamed COLUMNS cannot be aliased (their tables keep their names): old code
# that names music_video_slug fails until the new dynos take over. Only the admin
# video pages and the Mac pipeline scripts name it; the PR lists what breaks.
#
# The two views go in a LATER migration (its own task), once no release older than
# this one can be running. Their SQL stays here, not in db/views, so a baseline
# regeneration never makes the temporary views permanent; test/db/video_compat_views_test.rb
# builds them from the constants below and writes through them.
#
# The baseline marker reads the literal rename_table / rename_column lines above
# `down` (DbBaseline.renamed_tables / renamed_columns), so a database past this
# migration is not short of the baseline's music_video_slug columns.
class RenameMusicVideosToVideos < ActiveRecord::Migration[8.1]
  MUSIC_VIDEOS_VIEW = <<~SQL.freeze
    CREATE VIEW music_videos AS
    SELECT * FROM videos
  SQL

  MUSIC_VIDEO_ARTISTS_VIEW = <<~SQL.freeze
    CREATE VIEW music_video_artists AS
    SELECT id, artist_slug, created_at, video_slug AS music_video_slug, position, role, updated_at
    FROM video_artists
  SQL

  # table => polymorphic type columns that could name the renamed classes.
  POLYMORPHIC = {
    "error_logs" => %w[target_type parent_type],
    "active_storage_attachments" => %w[record_type],
    "image_caches" => %w[owner_type],
    "studio_links" => %w[linkable_type],
    "facts" => %w[subject_type],
    "gate_runs" => %w[subject_type]
  }.freeze
  CLASSES = { "MusicVideo" => "Video", "MusicVideoArtist" => "VideoArtist" }.freeze

  def up
    execute("SET LOCAL lock_timeout = '5s'")

    rename_table "music_videos", "videos"
    rename_table "music_video_artists", "video_artists"
    execute("ALTER TABLE videos RENAME CONSTRAINT music_videos_stage_known TO videos_stage_known")

    rename_column "alt_videos", "music_video_slug", "video_slug"
    rename_column "appearances", "music_video_slug", "video_slug"
    rename_column "video_artists", "music_video_slug", "video_slug"
    rename_column "video_chunk_takes", "music_video_slug", "video_slug"
    rename_column "video_clips", "music_video_slug", "video_slug"
    rename_column "video_performers", "music_video_slug", "video_slug"
    rename_column "video_stitches", "music_video_slug", "video_slug"

    retype(CLASSES)

    execute(MUSIC_VIDEOS_VIEW)
    execute(MUSIC_VIDEO_ARTISTS_VIEW)
  end

  def down
    execute("SET LOCAL lock_timeout = '5s'")

    execute("DROP VIEW IF EXISTS music_video_artists")
    execute("DROP VIEW IF EXISTS music_videos")

    retype(CLASSES.invert)

    rename_column "video_stitches", "video_slug", "music_video_slug"
    rename_column "video_performers", "video_slug", "music_video_slug"
    rename_column "video_clips", "video_slug", "music_video_slug"
    rename_column "video_chunk_takes", "video_slug", "music_video_slug"
    rename_column "video_artists", "video_slug", "music_video_slug"
    rename_column "appearances", "video_slug", "music_video_slug"
    rename_column "alt_videos", "video_slug", "music_video_slug"

    execute("ALTER TABLE videos RENAME CONSTRAINT videos_stage_known TO music_videos_stage_known")
    rename_table "video_artists", "music_video_artists"
    rename_table "videos", "music_videos"
  end

  private

  def retype(classes)
    POLYMORPHIC.each do |table, columns|
      next unless table_exists?(table)

      columns.each do |column|
        classes.each do |from, to|
          execute("UPDATE #{connection.quote_table_name(table)} SET #{connection.quote_column_name(column)} = " \
                  "#{connection.quote(to)} WHERE #{connection.quote_column_name(column)} = #{connection.quote(from)}")
        end
      end
    end
  end
end
