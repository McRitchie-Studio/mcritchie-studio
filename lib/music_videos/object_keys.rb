# frozen_string_literal: true

module MusicVideos
  # The snake_case R2 keys the pipeline plan names:
  #   music_videos/<artist>/<video>/source/<artists>_<video>_feat_<…>.mp4
  class ObjectKeys
    PREFIX = "music_videos/"

    def self.snake(text)
      text.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase
          .gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end

    # music_videos/<artist>/<video>/clips/<video>_clip_<NN>_<seam>_<shape>_<mmss>_<mmss>.mp4,
    # in the source's own folder.
    def self.clip(source_key:, ordinal:, seam:, cast_shape:, start_ms:, end_ms:)
      m = video_folder(source_key)
      "#{m[1]}clips/#{m[2]}_clip_#{format('%02d', ordinal)}_#{seam}_#{cast_shape}_#{mmss(start_ms)}_#{mmss(end_ms)}.mp4"
    end

    # music_videos/<artist>/<video>/chunks/<video>_chunk_<NN>_<mmss>_<mmss>.mp4:
    # one tile of the whole video (ChunkTiler), beside the clips folder.
    def self.chunk(source_key:, ordinal:, start_ms:, end_ms:)
      m = video_folder(source_key)
      "#{m[1]}chunks/#{m[2]}_chunk_#{format('%02d', ordinal)}_#{mmss(start_ms)}_#{mmss(end_ms)}.mp4"
    end

    # music_videos/<artist>/<video>/generated/<video>_chunk_<NN>_<mmss>_<mmss>_take_<NN>.mp4:
    # one generated MP4 the operator uploaded back for that chunk. The chunk's
    # own file name with the take number, so the two sort together.
    def self.take(source_key:, ordinal:, start_ms:, end_ms:, number:)
      m = video_folder(source_key)
      "#{m[1]}generated/#{m[2]}_chunk_#{format('%02d', ordinal)}_#{mmss(start_ms)}_#{mmss(end_ms)}_take_#{format('%02d', number)}.mp4"
    end

    # [whole match, "music_videos/<artist>/<video>/", "<video>"] of a source key.
    def self.video_folder(source_key)
      %r{\A(#{PREFIX}[a-z0-9_]+/([a-z0-9_]+)/)source/}.match(source_key.to_s) ||
        raise(ArgumentError, "#{source_key.inspect} is not a music video source key")
    end

    def self.mmss(ms) = format("%02d%02d", ms.to_i / 60_000, ms.to_i / 1000 % 60)

    def initialize(primary:, featured:, song:)
      @primary = Array(primary).map { |n| segment(n) }
      @featured = Array(featured).map { |n| segment(n) }
      @song = segment(song)
      raise ArgumentError, "a primary artist is required" if @primary.empty?
    end

    def source_mp4 = "#{folder}#{stem}.mp4"

    def info_json = "#{folder}#{stem}.info.json"

    private

    def folder = "#{PREFIX}#{@primary.first}/#{@song}/source/"

    def stem
      base = [*@primary, @song].join("_")
      @featured.empty? ? base : "#{base}_feat_#{@featured.join('_')}"
    end

    def segment(text)
      snake = self.class.snake(text)
      raise ArgumentError, "#{text.inspect} has no key-safe characters" if snake.empty?

      snake
    end
  end
end
