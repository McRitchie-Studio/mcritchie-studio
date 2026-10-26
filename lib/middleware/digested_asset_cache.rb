# frozen_string_literal: true

# DigestedAssetCache: a year of cache for a file whose name changes when it does.
#
# config.public_file_server.headers is one header for everything ActionDispatch::Static
# serves out of public/, and public/ holds two kinds of file. Fingerprinted
# /assets/* (the Propshaft digest is in the name, so an edit is a new URL) can be
# cached for a year and marked immutable; the home hero is one of them, moved into
# app/assets/images/hero. The unfingerprinted files beside them (the portraits
# under /agents/, the brand kit, og.png, the email images, robots.txt) keep their
# names when they are replaced, so a year there would pin a stale file in browsers
# for a year. production.rb keeps the week for those; this raises the
# fingerprinted ones to a year (lane-ui-infrastructure P3; config/ui_budget.yml
# assets_cached_one_year_pct).
#
# It sits just outside ActionDispatch::Static and rewrites only a 200 whose path is
# a digested asset, so a miss that falls through to the router (a 404) is never
# told to cache for a year.
class DigestedAssetCache
  ONE_YEAR = "public, max-age=#{365 * 24 * 60 * 60}, immutable".freeze

  # /assets/<logical name>-<digest>.<ext>[.gz|.br]. Propshaft's digest is the first
  # 8 hex of a SHA1 (Propshaft::Asset#digest); Sprockets 4 wrote 64. Eight or more
  # takes both, so a slug precompiled before the move still rides the year, while
  # an undigested name (application.css, denver-hero-1280.avif) never matches.
  DIGESTED = %r{\A/assets/.+-[0-9a-f]{8,}\.[A-Za-z0-9.]+\z}

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    if status.to_i == 200 && DIGESTED.match?(env["PATH_INFO"].to_s)
      # Rack 3 headers are lower-case, but a plain Hash may still carry the old
      # spelling: drop every case of the name so exactly one header goes out.
      headers.keys.each { |name| headers.delete(name) if name.to_s.casecmp?("cache-control") }
      headers["cache-control"] = ONE_YEAR
    end
    [ status, headers, body ]
  end
end
