# frozen_string_literal: true

require "json"

# ReleaseAnnounce — the conductor-machine half of `bin/release announce <release>`
# (and of `bin/release cycle`, which runs it once prod verify is green): smoke each
# production app, then hand the verdicts to the hub, which posts the release on
# Slack (Release::Conductor.announce_release → ReleaseNotes::SlackAnnouncement).
#
# WHY HERE. The soul that speaks for an app on Slack cannot run a smoke itself: a
# dispatched soul answers with no tools (AgentMailbox::Responder). So the checks run
# in code where the cycle already checks production (curl), and the hub posts the
# verdict in that soul's voice in the app post's thread.
#
# WHY THE SEAM IS `conductor()` (heroku run rails runner), not an HTTP endpoint: the
# ship already records itself and posts its Discord notes through that seam, under
# the agent lane's Heroku token the cycle holds; an endpoint would need an admin
# session token on this machine for no gain.
#
# PURE. Every network call is a lambda the caller passes, so the shape is unit-tested.
module ReleaseAnnounce
  # The pages every app's smoke checks: /up (the app's health) and home.
  PATHS = ["/up", "/"].freeze

  module_function

  # { repo => { "checks" => [{ "path", "url", "code", "ok" }], "sha" => verdict } }.
  # +targets+ is [[repo, base_url], ...] (ReleaseCycle.verify_targets :prod);
  # +http_status+ answers a URL's status code as a String, or nil; +sha_verdicts+
  # is prod verify's [{ "repo", "sha", "ok", "reason" }], or nil when unread.
  def smoke(targets, http_status:, sha_verdicts: nil)
    by_repo = Array(sha_verdicts).select { |v| v.is_a?(Hash) }.to_h { |v| [v["repo"].to_s, v] }
    Array(targets).to_h do |repo, base|
      checks = PATHS.map do |path|
        url = path == "/" ? "#{base}/" : "#{base}#{path}"
        code = http_status.call(url)
        { "path" => path, "url" => url, "code" => code.to_s, "ok" => code.to_s == "200" }
      end
      entry = { "checks" => checks }
      entry["sha"] = by_repo[repo.to_s].slice("sha", "ok", "reason") if by_repo[repo.to_s]
      [repo.to_s, entry]
    end
  end

  def green?(entry) = entry["checks"].all? { |c| c["ok"] } && (entry["sha"].nil? || entry["sha"]["ok"])

  # One line per smoked app, for the terminal.
  def smoke_lines(smoke)
    smoke.map do |repo, entry|
      checks = entry["checks"].map { |c| "#{c['path']} #{c['code'].to_s.empty? ? 'no answer' : c['code']}" }.join(", ")
      "  #{green?(entry) ? '✓' : '✗'} smoke #{repo}: #{checks}#{entry['sha'] && !entry['sha']['ok'] ? ' · SHA not proven' : ''}"
    end
  end

  # The hub snippet: Release::Conductor.announce_release, its result as one JSON line.
  def ruby(slug, smoke, dry_run:)
    "r = Release.find_by!(slug: #{slug.to_s.inspect}); " \
      "a = Release::Conductor.announce_release(release: r, smoke: JSON.parse(#{JSON.generate(smoke).inspect}), " \
      "dry_run: #{dry_run ? 'true' : 'false'}); " \
      "puts(a.to_json)"
  end

  # The terminal lines for the hub's answer: each post, then the Exit Seam line.
  def result_lines(result)
    result = {} unless result.is_a?(Hash)
    posts = Array(result["posts"]).map do |p|
      where = p["channel"] ? " #{p['channel']}" : ""
      who = p["soul"] ? " as #{p['soul']}" : ""
      why = p["error"] ? " — #{p['error']}" : ""
      "  #{p['status'] == 'sent' || p['status'] == 'already' ? '✓' : '·'} slack #{p['what']}#{where}#{who}: #{p['status']}#{why}"
    end
    posts + ["  #{result['line'] || 'Slack posts: no answer from the hub'}"]
  end
end
