require "time"
require_relative "../espn/team_record"
require_relative "../x/post_draft"

module Tiktok
  # The caption for a clip going to the operator's TikTok drafts, written by
  # code, the same every time (recast pipeline, piece 19). No model writes it.
  #
  #   input   the team (name, location, mascot, slogan hashtag), the same
  #           X::PostDraft::Team the X recipe takes
  #   output  "Cowboys 3-2 #nfl #nfltiktok #footballtiktok #dallascowboys #cowboys #fyp"
  #           plus the facts it read and anything a person should look at
  #
  # It shares the X recipe's machinery and copies none of it: the record is
  # Espn::TeamRecord (the reads X::PostDraft makes), the tag spelling is
  # X::PostDraft.tag, the team's slogan tag comes from the same team table.
  # What differs is the hashtag set, TikTok's own: HASHTAGS below.
  #
  # The hashtag set is a CONSTANT, not a table. It is one fixed list for every
  # clip, changed only by a reviewed diff, exactly like X::PostDraft::LEAGUE_TAGS;
  # a table would be a second place to edit with no screen to edit it on. The
  # per-team part (the slogan tag) already lives in the teams table.
  #
  # NFL only: ESPN's record read is the NFL feed. A team in another league is
  # refused rather than captioned without its record.
  class ClipCaption
    # Before the team's tags: the league, then TikTok's own discovery tags.
    LEAD_TAGS = %w[#nfl #nfltiktok #footballtiktok].freeze
    # After the team's tags.
    TAIL_TAGS = %w[#fyp].freeze
    # The whole set never passes this many tags (lead 3 + slogan + mascot + tail 1).
    MAX_HASHTAGS = 6
    # TikTok's caption limit: 2,200 characters, counted in UTF-16 code units.
    MAX_CHARS = 2_200
    LEAGUE = "nfl".freeze

    Result = Struct.new(:text, :facts, :exceptions, keyword_init: true)

    class Error < StandardError; end

    def initialize(team:, league:, fetch: nil, now: Time.now)
      @team = team
      @league = league.to_s.downcase
      @fetch = fetch
      @now = now
    end

    def call
      unless @league == LEAGUE
        raise Error, "#{@team.name} is a #{@league.empty? ? 'team with no league' : @league.upcase} team; " \
                     "only an NFL team's record can be read"
      end

      reading = Espn::TeamRecord.new(team_name: @team.name, fetch: @fetch).call
      text = text(reading.record)
      raise Error, "the caption runs #{self.class.length(text)} characters, over TikTok's #{MAX_CHARS}" if self.class.length(text) > MAX_CHARS

      Result.new(text:, facts: facts(reading), exceptions: exceptions(reading))
    rescue Espn::TeamRecord::Error => e
      raise Error, e.message
    end

    # The hashtags for a team, in order, never repeated, at most MAX_HASHTAGS.
    def self.hashtags(team)
      slogan = team.hashtag.to_s.strip.downcase
      [*LEAD_TAGS, slogan, X::PostDraft.tag(team.mascot), *TAIL_TAGS]
        .reject { |t| t.length < 2 }.uniq.first(MAX_HASHTAGS)
    end

    # TikTok counts a caption in UTF-16 code units: an emoji is two.
    def self.length(text) = text.to_s.encode("UTF-16LE").bytesize / 2

    private

    def text(record) = "#{@team.mascot} #{record} #{self.class.hashtags(@team).join(' ')}"

    def facts(reading)
      { "team" => @team.name, "record" => reading.record, "last_final" => reading.last_final,
        "hashtags" => self.class.hashtags(@team), "source" => Espn::TeamRecord::SOURCE, "read_at" => @now.utc.iso8601 }
    end

    # Reasons a person should look before posting. Empty means standard copy.
    # Unlike X's recipe a clip is not a "this team won" post, so a loss is no
    # reason to stop.
    def exceptions(reading)
      out = []
      out << "#{@team.name} has no slogan hashtag on file" if @team.hashtag.to_s.strip.empty?
      out << "ESPN shows no finished game for #{@team.name} this season" if reading.last_final.nil?
      out
    end
  end
end
