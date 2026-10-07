require "net/http"
require "json"
require "uri"
require_relative "api"

module Espn
  # One NFL team's season as ESPN reports it NOW: the record summary ("4-0")
  # and its most recent finished game. Three reads: the team list (to find
  # ESPN's id for the name), the team (the record) and its schedule (the last
  # final).
  #
  # Extracted from X::PostDraft so the two caption recipes that print a record,
  # X's (X::PostDraft) and TikTok's (Tiktok::ClipCaption), read it ONE way.
  # Pure Ruby, no Rails: bin/x-post loads it with require_relative.
  #
  # EVERY NUMBER IS READ, NEVER RECALLED. A read that fails raises Error; the
  # callers refuse to write a record they could not read.
  class TeamRecord
    BASE = "https://#{Api::WEB_HOST}/apis/site/v2/sports/football/nfl".freeze
    SOURCE = "ESPN (#{Api::WEB_HOST})".freeze

    class Error < StandardError; end

    Reading = Struct.new(:record, :last_final, keyword_init: true)

    # team_name: the full name ESPN displays ("Kansas City Chiefs").
    # fetch: url -> parsed JSON; nil means the real thing.
    def initialize(team_name:, fetch: nil)
      @team_name = team_name.to_s
      @fetch = fetch || method(:http_json)
    end

    def call
      espn_id = espn_team.fetch("id")
      record = @fetch.call("#{BASE}/teams/#{espn_id}").dig("team", "record", "items", 0, "summary")
      raise Error, "ESPN returned no record for #{@team_name}" if record.to_s.empty?

      Reading.new(record: record, last_final: last_final(espn_id))
    end

    private

    def espn_team
      teams = @fetch.call("#{BASE}/teams").dig("sports", 0, "leagues", 0, "teams") || []
      match = teams.map { |t| t["team"] }.find { |t| t["displayName"].to_s.casecmp?(@team_name) }
      match or raise Error, "ESPN lists no team named #{@team_name.inspect}"
    end

    # { kickoff, matchup, won, score, opponent, neutral_site } of the latest
    # completed game, or nil when the team has not finished one.
    def last_final(espn_id)
      events = @fetch.call("#{BASE}/teams/#{espn_id}/schedule")["events"] || []
      event  = events.select { |e| e.dig("competitions", 0, "status", "type", "completed") }.max_by { |e| e["date"].to_s }
      return nil unless event

      sides = event.dig("competitions", 0, "competitors") || []
      us    = sides.find { |s| s.dig("team", "id").to_s == espn_id.to_s }
      them  = sides.find { |s| s.dig("team", "id").to_s != espn_id.to_s }
      { "kickoff" => event["date"], "matchup" => event["shortName"], "won" => us && us["winner"] == true,
        "score" => "#{us&.dig('score', 'displayValue')}-#{them&.dig('score', 'displayValue')}",
        "opponent" => them&.dig("team", "displayName"), "neutral_site" => event.dig("competitions", 0, "neutralSite") == true }
    end

    def http_json(url)
      uri  = URI(url)
      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 12) do |h|
        h.get(uri.request_uri, "User-Agent" => Api::USER_AGENT, "Accept" => "application/json")
      end
      raise Error, "ESPN answered #{resp.code} for #{uri.path}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    rescue JSON::ParserError, SocketError, Timeout::Error, SystemCallError => e
      raise Error, "could not read ESPN (#{uri.path}): #{e.class}"
    end
  end
end
