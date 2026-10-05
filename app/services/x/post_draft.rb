require "net/http"
require "json"
require "uri"
require "time"
require_relative "../espn/api"

module X
  # Turns "this team won" into post copy, deterministically.
  #
  #   input   a team (name, location, mascot, slogan hashtag)
  #   output  "Chiefs 4-0 #nfl #nflfootball #chiefskingdom #kansascity #chiefs"
  #           plus the facts it read and anything that should stop a human.
  #
  # Pure logic over three ESPN reads — no Rails, so bin/x-post and the app share
  # ONE implementation and cannot drift into two copies of the recipe.
  #
  # EVERY NUMBER IS READ, NEVER RECALLED. The record comes from ESPN at draft
  # time, and the draft checks that the team's most recent final really was a
  # win: the input says the team won, and a record that has not caught up yet
  # is the one way this recipe publishes something false.
  class PostDraft
    # The host and the name come from Espn::Api, the one place this app spells
    # them: ESPN's other host 403s every Ruby client, whatever it calls itself.
    ESPN = "https://#{Espn::Api::WEB_HOST}/apis/site/v2/sports/football/nfl".freeze
    LEAGUE_TAGS = %w[#nfl #nflfootball].freeze
    STALE_AFTER = 8 * 24 * 60 * 60 # a final older than this is last week's game

    Team   = Struct.new(:name, :location, :mascot, :hashtag, keyword_init: true)
    Result = Struct.new(:text, :facts, :exceptions, keyword_init: true)

    class Error < StandardError; end

    def initialize(team:, fetch: nil, now: Time.now)
      @team  = team
      @fetch = fetch || method(:http_json)
      @now   = now
    end

    def call
      espn   = espn_team
      record = @fetch.call("#{ESPN}/teams/#{espn.fetch('id')}").dig("team", "record", "items", 0, "summary")
      raise Error, "ESPN returned no record for #{@team.name}" if record.to_s.empty?

      game = last_final(espn.fetch("id"))
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

    def espn_team
      teams = @fetch.call("#{ESPN}/teams").dig("sports", 0, "leagues", 0, "teams") || []
      match = teams.map { |t| t["team"] }.find { |t| t["displayName"].to_s.casecmp?(@team.name.to_s) }
      match or raise Error, "ESPN lists no team named #{@team.name.inspect}"
    end

    def last_final(espn_id)
      events = @fetch.call("#{ESPN}/teams/#{espn_id}/schedule")["events"] || []
      event  = events.select { |e| e.dig("competitions", 0, "status", "type", "completed") }.max_by { |e| e["date"].to_s }
      return nil unless event

      sides = event.dig("competitions", 0, "competitors") || []
      us    = sides.find { |s| s.dig("team", "id").to_s == espn_id.to_s }
      them  = sides.find { |s| s.dig("team", "id").to_s != espn_id.to_s }
      { "kickoff" => event["date"], "matchup" => event["shortName"], "won" => us && us["winner"] == true,
        "score" => "#{us&.dig('score', 'displayValue')}-#{them&.dig('score', 'displayValue')}",
        "opponent" => them&.dig("team", "displayName"), "neutral_site" => event.dig("competitions", 0, "neutralSite") == true }
    end

    def text(record, game)
      slot = game && self.class.slot_tag(Time.parse(game["kickoff"]))
      tags = [*LEAGUE_TAGS, @team.hashtag.to_s.strip.downcase, self.class.tag(@team.location), self.class.tag(@team.mascot), slot]
      "#{@team.mascot} #{record} #{tags.compact.reject { |t| t.length < 2 }.uniq.join(' ')}"
    end

    def facts(record, game)
      { "team" => @team.name, "record" => record, "last_final" => game,
        "source" => "ESPN (#{Espn::Api::WEB_HOST})", "read_at" => @now.utc.iso8601 }
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

    def http_json(url)
      uri  = URI(url)
      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 12) do |h|
        h.get(uri.request_uri, "User-Agent" => Espn::Api::USER_AGENT, "Accept" => "application/json")
      end
      raise Error, "ESPN answered #{resp.code} for #{uri.path}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    rescue JSON::ParserError, SocketError, Timeout::Error, SystemCallError => e
      raise Error, "could not read ESPN (#{uri.path}): #{e.class}"
    end
  end
end
