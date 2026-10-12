# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261012020000_rename_music_videos_to_videos.rb").to_s

# [integration] The rename's compatibility views (db/migrate/20261012020000):
# for the seconds Heroku's release phase runs the new schema under the old
# code, music_videos and music_video_artists must still read and write. A view
# never dumps to the :ruby schema, so this test DB lacks them; each test builds
# them from the migration's own SQL inside the test transaction and writes
# through them as the old code would.
class VideoCompatViewsTest < ActiveSupport::TestCase
  M = RenameMusicVideosToVideos

  setup do
    @connection = ActiveRecord::Base.connection
    @connection.execute(M::MUSIC_VIDEOS_VIEW)
    @connection.execute(M::MUSIC_VIDEO_ARTISTS_VIEW)
    Artist.create!(slug: "test-artist-a", name: "Test Artist A", kind: "person")
  end

  def value(sql) = @connection.select_value(sql)

  test "[integration] the old table name reads, inserts, updates and deletes the videos rows, defaults included" do
    id = value(<<~SQL)
      INSERT INTO music_videos (slug, platform, source_url, source_id, title, source_object_key, created_at, updated_at)
      VALUES ('test-artist-a-compat-demo', 'youtube', 'https://youtu.be/compat', 'compat', 'Compat',
              'music_videos/test_artist_a/compat/source/a.mp4', now(), now())
      RETURNING id
    SQL
    video = Video.find(id)
    assert_equal %w[music_video digested], [video.kind, video.stage], "the base table's defaults apply through the view"

    @connection.execute("UPDATE music_videos SET title = 'Compat 2' WHERE slug = 'test-artist-a-compat-demo'")
    assert_equal "Compat 2", video.reload.title
    assert_equal 1, value("SELECT count(*) FROM music_videos WHERE slug = 'test-artist-a-compat-demo'")

    @connection.execute("DELETE FROM music_videos WHERE slug = 'test-artist-a-compat-demo'")
    assert_not Video.exists?(id)
  end

  test "[integration] the old artist links keep their old column name through the view" do
    Video.create!(slug: "test-artist-a-compat-demo", platform: "youtube", source_url: "https://youtu.be/compat",
                  source_id: "compat", title: "Compat", source_object_key: "music_videos/test_artist_a/compat/source/a.mp4")
    @connection.execute(<<~SQL)
      INSERT INTO music_video_artists (artist_slug, music_video_slug, role, created_at, updated_at)
      VALUES ('test-artist-a', 'test-artist-a-compat-demo', 'primary', now(), now())
    SQL

    link = VideoArtist.find_by!(video_slug: "test-artist-a-compat-demo")
    assert_equal [1, "primary"], [link.position, link.role]
    assert_equal "test-artist-a-compat-demo",
                 value("SELECT music_video_slug FROM music_video_artists WHERE artist_slug = 'test-artist-a'")
  end

  test "[unit] the views mirror every column, so the old code's SELECT * sees the same row" do
    assert_equal @connection.columns("videos").map(&:name), @connection.columns("music_videos").map(&:name)
    assert_equal @connection.columns("video_artists").map(&:name).map { |c| c == "video_slug" ? "music_video_slug" : c }.sort,
                 @connection.columns("music_video_artists").map(&:name).sort
  end

  test "[unit] the migration retypes every polymorphic column that could name the old classes" do
    polymorphic = ActiveRecord::Base.connection.tables.flat_map do |table|
      @connection.columns(table).filter_map { |c| [table, c.name] if c.name.end_with?("_type") && c.type == :string }
    end
    named = M::POLYMORPHIC.flat_map { |table, columns| columns.map { |c| [table, c] } }
    owner_columns = %w[record_type owner_type linkable_type target_type parent_type subject_type]
    assert_empty polymorphic.select { |_, c| owner_columns.include?(c) } - named,
                 "a polymorphic *_type column the migration does not retype"
    assert_equal({ "MusicVideo" => "Video", "MusicVideoArtist" => "VideoArtist" }, M::CLASSES)
  end
end
