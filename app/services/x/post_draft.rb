require "time"
require_relative "../espn/team_record"

module X
  # Turns "this team won" into post copy, deterministically.
  #
  #   input   a team (name, location, mascot, slogan hashtag)
  #   output  "Chiefs 4-0 #nfl #nflfootball #chiefskingdom #kansascity #chiefs"
  #           plus the facts it read and anything that should stop a human.
  #
  # Pure logic over three ESPN reads — no Rails, so bin/x-post and the app share
  # ONE implementation and cannot drift into two copies of the recipe. The reads
  # themselves are Espn::TeamRecord, which TikTok's recipe (Tiktok::ClipCaption)
  # shares; the tags are this class's, and `tag` is shared too.
  #
  # EVERY NUMBER IS READ, NEVER RECALLED. The record comes from ESPN at draft
  # time, and the draft checks that the team's most recent final really was a
  # win: the input says the team won, and a record that has not caught up yet
  # is the one way this recipe publishes something false.
  class PostDraft
    # The host and the name come from Espn::Api, the one place this app spells
    # them: ESPN's other host 403s every Ruby client, whatever it calls itself.
    ESPN = Espn::TeamRecord::BASE
    LEAGUE_TAGS = %w[#nfl #nflfootball].freeze
    STALE_AFTER = 8 * 24 * 60 * 60 # a final older than this is last week's game

    Team   = Struct.new(:name, :location, :mascot, :hashtag, keyword_init: true)
    Result = Struct.new(:text, :facts, :exceptions, keyword_init: true)

    # One error class for a failed read, whichever recipe asked.
    Error = Espn::TeamRecord::Error

    def initialize(team:, fetch: nil, now: Time.now)
      @team  = team
      @fetch = fetch
      @now   = now
    end

    def call
      reading = Espn::TeamRecord.new(team_name: @team.name, fetch: @fetch).call
      record, game = reading.record, reading.last_final
      Result.new(text: text(record, game), facts: facts(record, game), exceptions: exceptions(game))
    end

    # Eastern wall-clock time for a UTC instant, without a timezone library: the
    # CLI runs with no ActiveSupport. US rule: DST from the second Sunday of
    # March to the first Sunday of November, switching at 2am local.
    def self.eastern(utc)
      utc    = utc.getutc
      year   = utc.year
      starts = nth_sunday(year, 3, 2) + 7 * 3600          # 2am EST = 07:00 UTC
      ends   = nth_sunday(year, 11, 1) + 6 * 3600         # 2am EDT = 06:00 UTC
      utc + (utc >= starts && utc < ends ? -4 : -5) * 3600
    end

    def self.nth_sunday(year, month, nth)
      first = Time.utc(year, month, 1)
      Time.utc(year, month, 1 + (7 - first.wday) % 7 + 7 * (nth - 1))
    end

    # The prime-time tag for a kickoff, or nil for an ordinary window.
    def self.slot_tag(kickoff_utc)
      et = eastern(kickoff_utc)
      return "#tnf" if et.thursday?
      return "#mnf" if et.monday?
      return "#snf" if et.sunday? && et.hour >= 19

      nil
    end

    def self.tag(words)
      "##{words.to_s.downcase.gsub(/[^a-z0-9]/, '')}"
    end

    private

    def text(record, game)
      slot = game && self.class.slot_tag(Time.parse(game["kickoff"]))
      tags = [*LEAGUE_TAGS, @team.hashtag.to_s.strip.downcase, self.class.tag(@team.location), self.class.tag(@team.mascot), slot]
      "#{@team.mascot} #{record} #{tags.compact.reject { |t| t.length < 2 }.uniq.join(' ')}"
    end

    def facts(record, game)
      { "team" => @team.name, "record" => record, "last_final" => game,
        "source" => Espn::TeamRecord::SOURCE, "read_at" => @now.utc.iso8601 }
    end

    # Reasons a person should look before this goes out. Empty means standard copy.
    def exceptions(game)
      out = []
      out << "#{@team.name} has no slogan hashtag on file" if @team.hashtag.to_s.strip.empty?
      if game.nil?
        out << "ESPN shows no finished game for #{@team.name} this season"
      else
        out << "ESPN's most recent final for #{@team.name} is a LOSS (#{game['matchup']}, #{game['score']}); the record may not have caught up, or this is the wrong team" unless game["won"]
        out << "the most recent final (#{game['matchup']}) kicked off #{game['kickoff']}, more than a week ago" if @now - Time.parse(game["kickoff"]) > STALE_AFTER
      end
      out
    end
  end
end
