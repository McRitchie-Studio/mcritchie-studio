module MusicVideos
  # Who is on screen in each chunk, from the video's cast as it is now, and the
  # prompt that follows from it. bin/digest-video cuts the chunks before there
  # is any cast, so they arrive "unknown" with nobody present; the hub labels
  # them when the vision pass posts the performers and again when the operator
  # confirms the cast (naming artists and extras changes who is a principal).
  # The same rule the Mac applies when it tiles a cast video (ClipCast.label).
  # The seam candidates are never relabelled: they are picked with the cast.
  class LabelChunks
    CAST_FIELDS = %w[ordinal artist_slug extra sightings].freeze

    def self.call(video) = new(video).call

    def initialize(video)
      @video = video
    end

    # Returns how many chunks changed.
    def call
      @video.video_performers.reset
      cast = @video.video_performers.map { |p| p.as_json(only: CAST_FIELDS) }
      @video.video_chunks.reset
      @video.video_chunks.count do |chunk|
        chunk.association(:music_video).target = @video
        seen = ClipCast.label(cast, chunk.start_ms, chunk.end_ms)
        chunk.assign_attributes(cast_shape: seen.cast_shape, target_performer: seen.target, performer_ordinals: seen.present)
        chunk.prompt = ClipPrompts.for(chunk)
        next false unless chunk.changed?

        chunk.save!
        true
      end
    end
  end
end
