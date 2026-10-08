# frozen_string_literal: true

# Stand-ins for the two outside parties of a TikTok draft (recast pipeline,
# piece 19): ESPN, which the caption reads the record from, and TikTok, which
# takes the upload. Synthetic: a fixed season and a TikTok that records what it
# was sent. Nothing here reaches the network.
module TiktokDraftFakes
  # ESPN for every team named: id 7, a 3-2 record, one finished game.
  def self.espn(record: "3-2", finished: true, names: nil)
    lambda do |url|
      case url
      when %r{/teams\z}
        listed = names || Team.where(league: "nfl").pluck(:name)
        { "sports" => [{ "leagues" => [{ "teams" => listed.each_with_index.map { |n, i| { "team" => { "id" => (i + 7).to_s, "displayName" => n } } } }] }] }
      when %r{/teams/\d+\z} then { "team" => { "record" => { "items" => [{ "summary" => record }] } } }
      when %r{/schedule\z}
        id = url[%r{/teams/(\d+)/}, 1]
        { "events" => [{ "date" => "2026-10-04T17:00Z", "shortName" => "SYN @ HOME",
                         "competitions" => [{ "neutralSite" => false, "status" => { "type" => { "completed" => finished } },
                                              "competitors" => [
                                                { "winner" => true, "score" => { "displayValue" => "24" }, "team" => { "id" => id } },
                                                { "winner" => false, "score" => { "displayValue" => "17" }, "team" => { "id" => "0", "displayName" => "Synthetic Opponent" } }
                                              ] }] }] }
      end
    end
  end

  # TikTok's inbox upload: remembers sizes and bytes; answers a status list in turn.
  class Uploader
    attr_reader :uploads, :status_reads

    def initialize(statuses: ["SEND_TO_USER_INBOX"], fail_with: nil, publish_id: "v_inbox_file~synthetic.1")
      @statuses = statuses.dup
      @fail_with = fail_with
      @publish_id = publish_id
      @uploads = []
      @status_reads = 0
    end

    def call(size:, read:)
      plan = Tiktok::InboxUpload.plan(size)
      yield(:initialized, @publish_id) if block_given?
      bytes = plan.ranges.map { |first, last| read.call(first, last - first + 1) }.join
      raise Tiktok::InboxUpload::Error, @fail_with if @fail_with

      @uploads << { size:, bytes: bytes.bytesize }
      { publish_id: @publish_id, plan: }
    end

    def status(_publish_id)
      @status_reads += 1
      status = @statuses.size > 1 ? @statuses.shift : @statuses.first
      status == "FAILED" ? { "status" => "FAILED", "fail_reason" => "file_format_check_failed" } : { "status" => status }
    end
  end

  # R2: every object is `size` bytes of "x".
  class Reader
    attr_reader :reads

    def initialize(size: 3_000)
      @size = size
      @reads = []
    end

    def size(_key) = @size

    def read(key, offset, length)
      @reads << [key, offset, length]
      "x" * length
    end
  end
end
