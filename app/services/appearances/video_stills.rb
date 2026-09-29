module Appearances
  # A music-video look's references: that performer's stills from the video,
  # clearest first (VideoPerformer#reference_still_keys). The objects are private,
  # so each is handed out as a short-lived signed URL, signed at the moment of use.
  module VideoStills
    TTL = 15.minutes.to_i

    def self.keys(appearance) = appearance&.video_performer&.reference_still_keys || []

    # Empty when the store is not reachable: the build then refuses for want of
    # an anchor rather than sending nothing.
    def self.urls(appearance, source: AssetBrowser.source)
      keys(appearance).map { |key| source.signed_url(key: key, expires_in: TTL) }
                      .select { |url| FetchableUrl.ok?(url) }
    rescue AssetBrowser::Unavailable
      []
    end
  end
end
