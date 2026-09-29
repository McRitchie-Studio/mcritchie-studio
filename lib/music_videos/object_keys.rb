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
