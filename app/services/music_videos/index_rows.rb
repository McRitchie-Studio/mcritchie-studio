# frozen_string_literal: true

module MusicVideos
  # The /music_videos index: one row per source video, newest first, each with
  # its cast count, its A/B/C frame state and its alt videos.
  #
  # Loads the whole page in a fixed number of queries, however many videos
  # there are (QUERIES; test/services/music_videos/index_rows_test.rb counts
  # them): the videos, their cast cards, their chunks, their alt videos, and
  # two grouped counts over the alt videos' clips and TikTok drafts. Everything
  # else is read off those rows.
  module IndexRows
    QUERIES = 6
    # Name suffixes a chip skips to reach the surname: "Odell Beckham Jr." is Beckham.
    SUFFIXES = %w[jr jr. sr sr. ii iii iv v].freeze
    # How many surnames an alt video chip spells out before it trails off.
    CHIP_NAMES = 3

    Row = Data.define(:video, :carded, :swapped, :chunks, :frames_missing, :thumbnail_key, :alts) do
      # nil when the video is not tiled into chunks yet: no clip can owe frames.
      def frames_state
        return :untiled if chunks.zero?

        frames_missing.zero? ? :complete : :missing
      end
    end

    Alt = Data.define(:alt_video, :surnames, :swap_count, :with_primary, :clips, :drafts_sent) do
      def number = alt_video.number

      # "Alt 1 · Purdy, Kittle, McCaffrey…", or "Alt 2 · nobody swapped".
      def label
        names = surnames.first(CHIP_NAMES).join(", ")
        names += "…" if surnames.size > CHIP_NAMES
        "Alt #{number} · #{names.presence || 'nobody swapped'}"
      end
    end

    module_function

    def call(scope = MusicVideo.all)
      videos = scope.order(created_at: :desc, id: :desc).to_a
      return [] if videos.empty?

      slugs = videos.map(&:slug)
      performers = VideoPerformer.where(music_video_slug: slugs).order(:ordinal).group_by(&:music_video_slug)
      chunks = VideoClip.where(music_video_slug: slugs, kind: "chunk").order(:ordinal).group_by(&:music_video_slug)
      alt_videos = AltVideo.where(music_video_slug: slugs).order(:number).to_a
      alts = alt_rows(alt_videos).group_by { |alt| alt.alt_video.music_video_slug }

      videos.map do |video|
        cast = performers.fetch(video.slug, [])
        tiles = chunks.fetch(video.slug, [])
        Row.new(video:, carded: cast.size, swapped: cast.count(&:swap?), chunks: tiles.size,
                frames_missing: MissingReferences.chunks(tiles, cast).size,
                thumbnail_key: cast.lazy.flat_map(&:reference_still_keys).first,
                alts: alts.fetch(video.slug, []))
      end
    end

    # Each alt video's chip: surnames off its swap snapshot, and two grouped
    # counts (clips with a primary version, drafts TikTok delivered).
    def alt_rows(alt_videos)
      return [] if alt_videos.empty?

      slugs = alt_videos.map(&:slug)
      clips = AltVideoClip.where(alt_video_slug: slugs)
      # A clip has a primary version exactly when it has any version (AltVideoClip#primary_version).
      counts = clips.left_joins(:versions).group(:alt_video_slug)
                    .pluck(:alt_video_slug, Arel.sql("COUNT(DISTINCT alt_video_clips.id)"),
                           Arel.sql("COUNT(DISTINCT alt_video_clip_versions.alt_video_clip_id)"))
                    .to_h { |slug, total, primary| [slug, [total, primary]] }
      drafts = TiktokDraft.where(state: "delivered").joins(:clip).where(alt_video_clips: { alt_video_slug: slugs })
                          .group("alt_video_clips.alt_video_slug").count

      alt_videos.map do |alt|
        total, primary = counts.fetch(alt.slug, [0, 0])
        entries = alt.swap_set.to_a
        Alt.new(alt_video: alt, surnames: entries.map { |e| surname(e.person_name) }, swap_count: entries.size,
                with_primary: primary, clips: total, drafts_sent: drafts.fetch(alt.slug, 0))
      end
    end

    # "Brock Purdy" -> "Purdy"; "Odell Beckham Jr." -> "Beckham".
    def surname(full_name)
      words = full_name.to_s.split
      words.pop while words.size > 1 && SUFFIXES.include?(words.last.downcase)
      words.last.to_s
    end
  end
end
