require "net/http"
require "openssl"

module ReleaseNotes
  class DiscordClient
    MissingWebhook = Class.new(StandardError)
    DeliveryError = Class.new(StandardError)
    # status/body are the LAST message's response; messages is how many were POSTed.
    Delivery = Struct.new(:status, :body, :messages, keyword_init: true)

    # Discord's per-message limits (https://discord.com/developers/docs/resources/message).
    # A message over any of them is refused with HTTP 400 — which is how
    # rel-20260925-3b1f5c's 27-task notes (2790 chars of `content`) never landed.
    CONTENT_LIMIT = 2000
    EMBEDS_PER_MESSAGE = 10
    EMBED_CHARS_PER_MESSAGE = 6000
    EMBED_TITLE_LIMIT = 256
    EMBED_DESCRIPTION_LIMIT = 4096
    EMBED_FOOTER_LIMIT = 2048

    # One retry on a 429, waiting what Discord asks for, capped so a bad header
    # cannot park a release run.
    RATE_LIMIT_MAX_WAIT = 5.0
    # Discord's error bodies say WHICH field broke; keep enough of it to read.
    ERROR_BODY_LIMIT = 500

    # Transport-level failures (DNS, refused, timeout, SSL, reset) — converted to
    # the typed DeliveryError so callers get one error contract instead of a
    # grab-bag of Net/Socket/SSL exceptions leaking out of `Net::HTTP.start`.
    TRANSPORT_ERRORS = [
      SocketError, SystemCallError, Timeout::Error, IOError,
      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
    ].freeze

    # Post a release-notes message: plain `content`, rich `embeds` (an array of
    # Discord embed hashes), or both. At least one must be present — the caller
    # (ReleaseNotes::Formatter#discord_payload) splats one or the other in. A
    # payload over Discord's limits is delivered as several messages (.messages).
    def self.deliver(content: nil, embeds: nil, webhook_url: nil)
      webhook_url = webhook_url.presence || self.webhook_url
      raise MissingWebhook, "Release notes webhook is not configured" if webhook_url.blank?

      new(webhook_url).deliver(content: content, embeds: embeds)
    end

    def self.webhook_url
      ENV["DISCORD_RELEASE_NOTES_WEBHOOK_URL"].presence || ENV["DISCORD_DEPLOY_WEBHOOK_URL"].presence
    end

    # Length as Discord counts it: UTF-16 code units (it is a JS string length), so
    # an emoji such as 🚀 costs 2. Counting Ruby characters would under-measure.
    def self.discord_length(text)
      text.to_s.encode("UTF-16LE").bytesize / 2
    end

    # The request bodies one delivery POSTs, in order — PURE, so a dry run can show
    # the split without sending anything. Content is split on line boundaries into
    # messages of at most CONTENT_LIMIT; the embeds ride from the LAST content
    # message on (so the header reads before the cards), at most EMBEDS_PER_MESSAGE
    # and EMBED_CHARS_PER_MESSAGE per message. Each embed is clipped to its own
    # field limits first.
    def self.messages(content: nil, embeds: nil)
      bodies = split_content(content.to_s).map { |chunk| { content: chunk } }
      batches = batch_embeds(Array(embeds).map { |embed| clip_embed(embed) })
      return bodies if batches.empty?

      if bodies.empty?
        bodies << { embeds: batches.shift }
      else
        bodies.last[:embeds] = batches.shift
      end
      bodies.concat(batches.map { |batch| { embeds: batch } })
    end

    def self.split_content(text)
      return [] if text.strip.empty?

      chunks = []
      current = nil
      text.split("\n", -1).flat_map { |line| hard_split(line) }.each do |line|
        candidate = current.nil? ? line : "#{current}\n#{line}"
        if discord_length(candidate) <= CONTENT_LIMIT
          current = candidate
        else
          chunks << current unless current.nil?
          current = line
        end
      end
      chunks << current unless current.nil?
      chunks.reject { |chunk| chunk.strip.empty? }
    end

    # A single line longer than the whole cap is cut into cap-sized pieces.
    def self.hard_split(line)
      return [line] if discord_length(line) <= CONTENT_LIMIT

      pieces = [+""]
      line.each_char do |char|
        pieces << +"" if discord_length(pieces.last + char) > CONTENT_LIMIT
        pieces.last << char
      end
      pieces
    end

    def self.batch_embeds(embeds)
      embeds.each_with_object([]) do |embed, batches|
        size = embed_length(embed)
        last = batches.last
        if last.nil? || last.size >= EMBEDS_PER_MESSAGE ||
           last.sum { |e| embed_length(e) } + size > EMBED_CHARS_PER_MESSAGE
          batches << [embed]
        else
          last << embed
        end
      end
    end

    # The characters Discord counts toward the 6000-per-message embed total.
    def self.embed_length(embed)
      embed = embed.with_indifferent_access
      parts = [embed[:title], embed[:description], embed.dig(:footer, :text), embed.dig(:author, :name)]
      Array(embed[:fields]).each { |field| parts.push(field[:name] || field["name"], field[:value] || field["value"]) }
      parts.sum { |part| discord_length(part) }
    end

    def self.clip_embed(embed)
      clipped = embed.deep_dup
      clip!(clipped, :title, EMBED_TITLE_LIMIT)
      clip!(clipped, :description, EMBED_DESCRIPTION_LIMIT)
      footer = clipped[:footer] || clipped["footer"]
      clip!(footer, :text, EMBED_FOOTER_LIMIT) if footer.is_a?(Hash)
      clipped
    end

    def self.clip!(hash, key, limit)
      key = hash.key?(key.to_s) ? key.to_s : key
      value = hash[key]
      return unless value.is_a?(String) && discord_length(value) > limit

      value = value[0...-1] while discord_length("#{value}…") > limit
      hash[key] = "#{value}…"
    end
    private_class_method :split_content, :hard_split, :batch_embeds, :clip_embed, :clip!

    def initialize(webhook_url, sleeper: ->(seconds) { sleep(seconds) })
      @webhook_url = webhook_url
      @sleeper = sleeper
    end

    # POST each message in order. A failure raises DeliveryError naming the HTTP
    # status, Discord's own error body, and which message failed — the real cause,
    # for the caller to print. Messages before it have already been posted.
    def deliver(content: nil, embeds: nil)
      bodies = self.class.messages(content: content, embeds: embeds)
      response = nil
      bodies.each_with_index do |body, index|
        response = post(body)
        next if response.is_a?(Net::HTTPSuccess)

        raise DeliveryError, failure_message(response, index, bodies.size)
      end

      Delivery.new(status: response&.code.to_i, body: response&.body, messages: bodies.size)
    rescue *TRANSPORT_ERRORS => e
      raise DeliveryError, "Discord release notes delivery failed: #{e.class}: #{e.message}"
    end

    private

    def post(body, retried: false)
      uri = URI(@webhook_url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end
      return response unless response.code.to_s == "429" && !retried

      @sleeper.call(retry_after(response))
      post(body, retried: true)
    end

    def retry_after(response)
      seconds = JSON.parse(response.body.to_s)["retry_after"].to_f
      seconds = response["Retry-After"].to_f if seconds <= 0 && response["Retry-After"]
      seconds.clamp(0.5, RATE_LIMIT_MAX_WAIT)
    rescue JSON::ParserError
      1.0
    end

    def failure_message(response, index, total)
      where = total > 1 ? " on message #{index + 1} of #{total} (#{index} already posted)" : ""
      detail = response.body.to_s.strip.first(ERROR_BODY_LIMIT)
      message = "Discord release notes notification failed#{where}: HTTP #{response.code}"
      detail.empty? ? message : "#{message} #{detail}"
    end
  end
end
