module Media
  # Where a standalone post goes: a medium plus a named channel and its spec
  # (Media.home builds one; Media.post hands it to the medium's adapter).
  #
  #   medium     "discord", "slack", …
  #   channel    the logical channel name ("ops"), or nil for "no channel"
  #   spec       the channel's config ({ "id" => … } or { "webhook_env" => … })
  #   source     which level chose it: "purpose:floor_alert", "soul:avi", "app:…", "defaults"
  #   fell_from  the media skipped on the way (fallback), oldest first
  Home = Struct.new(:medium, :channel, :spec, :source, :fell_from, keyword_init: true) do
    def channel? = !channel.nil? && !spec.nil?

    # A Discord channel snowflake (the bot posts to it), or nil.
    def channel_id = spec && spec["id"].to_s.presence

    # The ENV names a webhook channel reads, in order.
    def webhook_envs = Array(spec && spec["webhook_env"]).map(&:to_s).reject(&:empty?)

    # The first set webhook URL, or nil. Never logged.
    def webhook_url = webhook_envs.lazy.map { |env| ENV[env].presence }.find(&:itself)

    # "discord #ops", for logs and copy. Never a URL.
    def label = channel ? "#{medium} ##{channel}" : "#{medium} (no channel)"
  end
end
