module X
  # Reads one post back from X to say what is actually live: whether a video is
  # attached, and how long it is. The create call returning an id proves a post
  # exists; it does not prove the media rode along.
  class ReadBack
    URL = "https://api.x.com/2/tweets".freeze

    def initialize(post_id, client: Client.new)
      @post_id = post_id.to_s
      @client  = client
    end

    # { "video" => true/false, "seconds" => Float or nil, "text" => String }
    def call
      resp  = @client.get("#{URL}/#{@post_id}", "expansions" => "attachments.media_keys", "media.fields" => "type,duration_ms")
      json  = @client.parse_json(resp)
      media = Array(json.dig("includes", "media")).find { |m| m["type"] == "video" }
      { "video" => !media.nil?, "seconds" => media && media["duration_ms"] ? (media["duration_ms"] / 1000.0).round(1) : nil,
        "text" => json.dig("data", "text").to_s }
    end
  end
end
