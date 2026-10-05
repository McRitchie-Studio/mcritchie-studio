module MusicVideos
  # Records a digested video: parses its credits, links the artists that resolve
  # and keeps the rest as unresolved_credits for the cast step. A video already
  # recorded (same platform and source id) is returned unchanged.
  class Digest
    Outcome = Struct.new(:video, :created) do
      def created? = created
    end

    ATTRIBUTES = %w[kind platform source_url source_id title duration_ms source_object_key info_object_key caption_timing].freeze

    def initialize(params, resolver: CreditResolver.new)
      @params = params.to_h.stringify_keys
      @resolver = resolver
    end

    def call
      existing = MusicVideo.find_by(platform: @params["platform"], source_id: @params["source_id"])
      return Outcome.new(existing, false) if existing

      credits = CreditParser.new(known: @resolver.method(:known?))
                            .parse(title: @params["title"], uploader: @params["uploader"],
                                   artists: Array(@params["credited_artists"]))
      video = MusicVideo.new(@params.slice(*ATTRIBUTES))
      video.slug = unique_slug([*credits.primary.first(1), credits.song].join(" "))

      link(video, credits)
      video.save!
      Outcome.new(video, true)
    end

    private

    def link(video, credits)
      unresolved = []
      { "primary" => credits.primary, "featured" => credits.featured }.each do |role, names|
        position = 0
        names.each do |name|
          result = @resolver.resolve(name)
          if result.artist.nil?
            unresolved << { "name" => name, "role" => role, "reason" => result.reason }
          elsif video.music_video_artists.none? { |c| c.artist_slug == result.artist.slug }
            video.music_video_artists.build(artist: result.artist, role: role, position: position += 1)
          end
        end
      end
      video.unresolved_credits = unresolved
    end

    def unique_slug(text)
      base = slugify(text).presence || slugify(@params["source_id"])
      MusicVideo.exists?(slug: base) ? "#{base}-#{slugify(@params['source_id'])}" : base
    end

    # parameterize keeps "_", which a slug may not hold; an Instagram shortcode
    # or a YouTube id can carry one.
    def slugify(text) = text.to_s.parameterize.gsub(/[-_]+/, "-").gsub(/\A-|-\z/, "")
  end
end
