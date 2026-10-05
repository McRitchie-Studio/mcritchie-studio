require "open-uri"

class Content
  # Publishes a video_post_x card to X. Deterministic: the copy and the video are
  # already on the card, and this decides nothing.
  #
  # TWO HALVES, because an upload plus X's processing outlasts a web request:
  #
  #   begin!  (the Post button)  checks everything, takes the card to `assembly`
  #                              with state "queued", enqueues the job.
  #   call    (the job)          posts, records the link, reads the post back.
  #
  # IT MUST NEVER POST TWICE, and the queue cannot promise that for us: a worker
  # that dies mid-job has its job handed to another worker. So the job's first
  # act is to move the card from "queued" to "posting" under a row lock, and a
  # run that finds any other state does not post. A card left in "posting" means
  # a run died somewhere between the upload and the record, and only the
  # timeline knows whether the video is live — the card says so and asks.
  class PostVideoToX
    ACCOUNT = "turfmonstershow".freeze
    ME_URL  = "https://api.x.com/2/users/me".freeze
    STUCK_AFTER = 10.minutes

    class Refused < StandardError; end

    def self.configured? = X::OAuthSigner.creds_present?

    # Why this card cannot be posted right now, or nil when it can.
    def self.refusal(content)
      return "only a Video Post (X) card posts this way" unless content.video_post_x?
      return "this card is already posted" if content.stage == "posted"
      return "a post is already in flight for this card" if content.stage == "assembly"
      return "there is no copy to post yet" if content.stage != "script" || content.captions.blank?
      return "there is no video on this card" if content.final_video_url.blank?

      problems = X::Caption.new(line: content.captions).problems
      return "the copy is not postable: #{problems.join('; ')}" if problems.any?
      return "the X keys are not set on this server" unless configured?

      nil
    end

    def self.begin!(content)
      content.with_lock do
        reason = refusal(content)
        raise Refused, reason if reason

        content.update!(stage: "assembly", game_facts: (content.game_facts || {}).merge(
          "post" => { "state" => "queued", "attempted_at" => Time.current.utc.iso8601 }
        ))
      end
      ContentPostVideoToXJob.perform_later(content.slug)
      content
    end

    # A run that started and never finished: the video may be live.
    def self.stuck?(content)
      post = (content.game_facts || {})["post"] || {}
      return false unless content.stage == "assembly"
      return true if post["state"] == "unknown"

      started = Time.zone.parse(post["attempted_at"].to_s)
      started.nil? || started < STUCK_AFTER.ago
    end

    def initialize(content, media: X::PostMedia, read_back: X::ReadBack, client: nil)
      @content   = content
      @media     = media
      @read_back = read_back
      @client    = client
    end

    def call
      return @content unless claim_run!

      account = whoami
      return not_posted!("these keys post as @#{account}, not @#{ACCOUNT}") unless account.casecmp?(ACCOUNT)

      result = Dir.mktmpdir("x-post-#{@content.slug}-") do |tmp|
        path = File.join(tmp, "video.mp4")
        download(@content.final_video_url, path)
        @media.new(text: @content.captions, video_path: path).call
      end
      record!(account, result[:post_id])
    rescue X::PostMedia::NotPosted, X::Client::HttpError, OpenURI::HTTPError => e
      # X (or the bucket) answered and nothing is live: hand the card back.
      not_posted!(e.message)
    rescue StandardError => e
      # Anything else is unknown. The card stays in `assembly` and says so.
      mark("state" => "unknown", "error" => e.message.to_s[0, 500])
      @content
    end

    private

    # queued → posting, once. Any other state means a run already started.
    def claim_run!
      @content.with_lock do
        post = (@content.game_facts || {})["post"] || {}
        next false unless @content.stage == "assembly" && post["state"] == "queued"

        mark("state" => "posting", "started_at" => Time.current.utc.iso8601)
        true
      end
    end

    def whoami
      client = @client || X::Client.new
      client.parse_json(client.get(ME_URL)).dig("data", "username").to_s
    end

    def record!(account, post_id)
      Content::Post.new(@content).call(platform: "x", post_id: post_id,
                                       post_url: "https://x.com/#{account}/status/#{post_id}")
      verified = begin
        @read_back.new(post_id, **(@client ? { client: @client } : {})).call
      rescue StandardError => e
        { "error" => e.message.to_s[0, 200] }
      end
      mark("state" => "posted", "verified" => verified)
      @content
    end

    def not_posted!(message)
      @content.update!(stage: "script")
      mark("state" => "refused", "error" => message.to_s[0, 500])
      @content
    end

    def mark(fields)
      facts = @content.game_facts || {}
      @content.update!(game_facts: facts.merge("post" => (facts["post"] || {}).merge(fields)))
    end

    def download(url, dest)
      URI.parse(url).open(read_timeout: 60) { |io| File.open(dest, "wb") { |f| IO.copy_stream(io, f) } }
    end
  end
end
