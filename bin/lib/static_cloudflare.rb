# frozen_string_literal: true

require "digest"
require "find"
require "json"
require "open3"
require "time"
require "uri"
require_relative "domain_cutover"

# StaticCloudflare — an app served as plain files from Cloudflare R2, with no
# Heroku dyno. The runbook is docs/agents/modules/static-cloudflare.md.
#
# Two callers, two units:
#
#   Deploy     build the app's static site in a checkout at the frozen SHA, upload
#              it to the app's R2 bucket, write the release marker, smoke the host.
#              bin/release's `static_cloudflare` prod_deploy strategy runs it on
#              every ship of an app already on Cloudflare.
#
#   Downgrade  the one-time move of a Heroku app to Cloudflare, for ANY app: a
#              Deploy, then point the host at the bucket (drop the old DNS record,
#              attach the R2 custom domain, add the index-document URL rewrite), smoke, and only
#              then scale the Heroku web dyno to 0 (rolling the host swap back on any failure). It is
#              the unit the hosting-trial daily job will call
#              (.agents/epics/hosting-trial-lifecycle.md); bin/static-downgrade is
#              its command line. It PLANS by default and writes only with
#              execute: true.
#
# Plain Ruby, no Rails: bin/release loads it standalone. Every network call goes
# through an injected transport (DomainCutover::Transport in production) and
# every subprocess through an injected runner, so the tests open no socket and
# run no aws.
#
# WHY R2 AND NOT PAGES OR WORKERS. The one Cloudflare credential an agent holds,
# cloudflare.studio.provision, grants R2 read/write, Transform Rules, DNS, Zone
# and the redirect rules, but no Workers Scripts or Pages scope (read from its
# policies 2026-10-25). An R2 custom domain serves the object at the key the path
# names and has no index document, so a zone URL REWRITE (a Transform Rule, phase
# http_request_transform) maps each page path to its index.html before R2 sees
# it; the address bar keeps the clean URL. Rewrite.key_for is the same mapping in
# Ruby, so the tests' stub host and the rule cannot disagree silently:
#   /, /x/          -> index.html, x/index.html     (the path ends in "/")
#   /x, /rants/x    -> x/index.html                  (no "." in the path)
#   /assets/a-1.css -> assets/a-1.css                (anything else: as it is)
# The one limit: a PAGE path containing a dot is not rewritten. The static build
# writes pages only at extension-free paths, so none exists today.
module StaticCloudflare
  class Abort < StandardError; end

  MARKER = "static-release.json"
  DEFAULT_BUILD_COMMAND = "bin/static-build"
  DEFAULT_BUILD_DIR = "tmp/static/site"
  DEFAULT_CREDENTIAL = "r2.static-sites"
  REWRITE_PHASE = "http_request_transform"
  REWRITE_REF_PREFIX = "static_cloudflare_"

  # What each extension is served as. An extension outside this list stops the
  # upload: R2 serves the stored Content-Type, so a guess would ship a wrong one.
  CONTENT_TYPES = {
    "html" => "text/html; charset=utf-8",
    "css" => "text/css; charset=utf-8",
    "js" => "text/javascript; charset=utf-8",
    "json" => "application/json; charset=utf-8",
    "map" => "application/json; charset=utf-8",
    "svg" => "image/svg+xml",
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "gif" => "image/gif",
    "webp" => "image/webp",
    "ico" => "image/x-icon",
    "woff2" => "font/woff2",
    "woff" => "font/woff",
    "txt" => "text/plain; charset=utf-8",
    "xml" => "application/xml; charset=utf-8",
    "webmanifest" => "application/manifest+json"
  }.freeze

  # The client-app host's cache policy (docs/agents/system/client-app-host.md):
  # a page revalidates every time, so a ship shows at once; a file whose name
  # carries a digest is cached a year; anything else five minutes.
  CACHE_PAGE = "no-cache"
  CACHE_DIGESTED = "public, max-age=31536000, immutable"
  CACHE_OTHER = "public, max-age=300"
  CACHE_MARKER = "no-store"
  DIGESTED = /-[0-9a-f]{8,}\.[a-z0-9]+\z/

  # One app's Cloudflare target, read from its release_repos.yml prod_deploy
  # adapter. Only `bucket` and `smoke_url` are required; the rest default.
  Target = Struct.new(:repo, :bucket, :host, :smoke_url, :heroku_app, :build_command, :build_dir,
                      :credential, keyword_init: true) do
    def self.from(repo, adapter)
      adapter ||= {}
      smoke = adapter["smoke_url"].to_s.strip.sub(%r{/+\z}, "")
      bucket = adapter["bucket"].to_s.strip
      raise Abort, "#{repo}: static_cloudflare adapter names no `bucket`" if bucket.empty?
      raise Abort, "#{repo}: static_cloudflare adapter names no `smoke_url`" if smoke.empty?

      host = smoke.sub(%r{\Ahttps?://}, "").split("/").first
      new(repo: repo, bucket: bucket, host: host, smoke_url: smoke,
          heroku_app: adapter["heroku_app"].to_s.strip,
          build_command: (adapter["build_command"] || DEFAULT_BUILD_COMMAND).to_s,
          build_dir: (adapter["build_dir"] || DEFAULT_BUILD_DIR).to_s,
          credential: (adapter["credential"] || DEFAULT_CREDENTIAL).to_s)
    end
  end

  # The Cloudflare target a Downgrade moves an app TO, from its CURRENT adapter:
  # an app already on static_cloudflare keeps its own; a git_push_heroku app gets
  # the convention (bucket `<heroku app>-static`, the same smoke_url, the Heroku
  # app read from its remote). The daily job calls this for any app.
  HEROKU_REMOTE = %r{\Ahttps://git\.heroku\.com/([a-z0-9][a-z0-9-]*)\.git\z}i

  def self.downgrade_target(repo, adapter)
    adapter ||= {}
    return Target.from(repo, adapter) if adapter["strategy"].to_s == "static_cloudflare"

    heroku_app = adapter["heroku_app"].to_s.strip
    heroku_app = adapter["remote"].to_s.strip[HEROKU_REMOTE, 1].to_s if heroku_app.empty?
    raise Abort, "#{repo}: no Heroku app named by its prod_deploy (heroku_app: or a git.heroku.com remote)" if heroku_app.empty?

    Target.from(repo, "bucket" => "#{heroku_app}-static", "smoke_url" => adapter["smoke_url"], "heroku_app" => heroku_app)
  end

  # The apps a downgrade may move: the unpaid showcase apps Alex ruled serve from
  # Cloudflare. Every other app (turf-monster, cyvasse, moms-app, a client app) is
  # refused before anything is read or written, whatever its profile says:
  # cyvasse and moms-app share standalone-heroku but hold a database. The
  # hosting-trial daily job adds an app here only from its own record of a lapsed,
  # unpaid trial.
  DOWNGRADABLE_APPS = %w[rantly dads-app 10and5 portfolio prisoners-dilemma search-position weekly-lock].freeze
  DOWNGRADE_PROFILES = %w[standalone-heroku standalone-static].freeze

  def self.refuse_unless_downgradable!(repo, entry)
    unless DOWNGRADABLE_APPS.include?(repo)
      raise Abort, "#{repo} is not an unpaid showcase app (#{DOWNGRADABLE_APPS.join(', ')}): " \
                   "a downgrade would take a paid app off its dyno. Nothing was read or written."
    end
    profile = entry.to_h["profile"].to_s
    return if DOWNGRADE_PROFILES.include?(profile)

    raise Abort, "#{repo} is on profile #{profile.empty? ? '(none)' : profile}, not #{DOWNGRADE_PROFILES.join(' or ')}: " \
                 "only a database-free standalone moves to R2. Nothing was read or written."
  end

  # The environment the static build runs under, by ALLOW-list: the toolchain's
  # own variables and nothing else, so no operator credential (1Password service
  # tokens, HEROKU_API_KEY, the Cloudflare token, a Bundler auth key) reaches
  # the app's code. Spawn it with unsetenv_others: true.
  BUILD_ENV_KEYS = %w[PATH HOME USER LOGNAME SHELL TMPDIR TERM LANG LC_ALL LC_CTYPE GEM_HOME GEM_PATH].freeze
  BUILD_ENV_PREFIXES = %w[MISE_ RBENV_].freeze

  def self.build_env(parent = ENV)
    parent.to_h.select do |key, _|
      BUILD_ENV_KEYS.include?(key) || BUILD_ENV_PREFIXES.any? { |prefix| key.start_with?(prefix) && !key.match?(/TOKEN|KEY|SECRET/) }
    end
  end

  # One object to write: its key, the local file, and the two headers R2 stores.
  Item = Struct.new(:key, :path, :content_type, :cache_control, keyword_init: true)

  # The zone URL rewrite that gives an R2 bucket its index documents, and the
  # same mapping in Ruby (key_for). Two rules, both using only functions every
  # Cloudflare plan has (ends_with, contains, concat; no regex).
  module Rewrite
    module_function

    def key_for(path)
      path = "/" if path.to_s.empty?
      key = if path.end_with?("/") then "#{path}index.html"
            elsif !path.include?(".") then "#{path}/index.html"
            else path
            end
      key.delete_prefix("/")
    end

    def rules(host)
      on_host = %(http.host eq "#{host}")
      ref = "#{REWRITE_REF_PREFIX}#{host.tr('.-', '__')}"
      [
        rule("#{ref}_dir", "#{host}: a path ending in / serves its index.html",
             %((#{on_host} and ends_with(http.request.uri.path, "/"))),
             %(concat(http.request.uri.path, "index.html"))),
        rule("#{ref}_page", "#{host}: an extension-free path serves its index.html",
             %((#{on_host} and not ends_with(http.request.uri.path, "/") and not http.request.uri.path contains ".")),
             %(concat(http.request.uri.path, "/index.html")))
      ]
    end

    def rule(ref, description, expression, path_expression)
      { "ref" => ref, "description" => "#{description} (static_cloudflare)", "expression" => expression,
        "action" => "rewrite",
        "action_parameters" => { "uri" => { "path" => { "expression" => path_expression } } },
        "enabled" => true }
    end
  end

  # The built directory as the objects to upload, in a safe order: every asset
  # first, then the pages, so a page never goes live naming a file not yet there.
  # (The release marker is written after all of them, by Deploy.)
  module Bundle
    REQUIRED = ["index.html", "up/index.html"].freeze

    module_function

    def items(dir)
      raise Abort, "the static build wrote no directory at #{dir}" unless File.directory?(dir)

      files = []
      Find.find(dir) do |path|
        next if File.directory?(path) && !File.symlink?(path)
        raise Abort, "#{relative(dir, path)} is a symlink: the bundle holds regular files only" if File.symlink?(path)

        files << relative(dir, path)
      end
      missing = REQUIRED - files
      raise Abort, "the static build is missing #{missing.join(', ')} (the smoke reads /up)" if missing.any?

      pages, assets = files.sort.flat_map { |file| for_file(dir, file) }.partition { |item| item.content_type.start_with?("text/html") }
      assets + pages
    end

    def for_file(dir, file)
      raise Abort, "#{file}: #{MARKER} is the release marker's key; the build may not write it" if file == MARKER

      ext = File.extname(file).delete_prefix(".").downcase
      type = CONTENT_TYPES[ext] or raise Abort, "#{file}: no Content-Type for .#{ext} (add it to StaticCloudflare::CONTENT_TYPES)"
      path = File.join(dir, file)
      cache = cache_for(file, type)
      [Item.new(key: file, path: path, content_type: type, cache_control: cache)]
    end

    def cache_for(file, type)
      return CACHE_PAGE if type.start_with?("text/html")
      return CACHE_DIGESTED if file.match?(DIGESTED)

      CACHE_OTHER
    end

    def relative(dir, path) = path.delete_prefix(File.join(dir, "")).to_s
  end

  # R2's S3 API through the aws CLI (installed on the ship machine), one
  # put-object per key so each carries its own Content-Type and Cache-Control.
  # The keys ride in the child's environment only; nothing prints them.
  class S3Uploader
    def initialize(credentials, runner: method(:run))
      @credentials = credentials
      @runner = runner
    end

    def put(bucket, item)
      argv = ["aws", "s3api", "put-object", "--endpoint-url", @credentials.fetch(:endpoint),
              "--bucket", bucket, "--key", item.key, "--body", item.path,
              "--content-type", item.content_type, "--cache-control", item.cache_control,
              "--only-show-errors"]
      env = { "AWS_ACCESS_KEY_ID" => @credentials.fetch(:access_key_id),
              "AWS_SECRET_ACCESS_KEY" => @credentials.fetch(:secret_access_key),
              "AWS_DEFAULT_REGION" => "auto", "AWS_PAGER" => "" }
      out, ok = @runner.call(argv, env)
      [ok, DomainCutover.redact(out, @credentials.values)]
    end

    def run(argv, env)
      out, status = Open3.capture2e(env, *argv)
      [out, status.success?]
    rescue Errno::ENOENT
      ["the aws CLI is not on PATH", false]
    end
  end

  # Credentials, read from 1Password by item name and never printed.
  module Credentials
    module_function

    # The upload keys: an R2 S3 key pair scoped to the static-site buckets.
    def r2(item, reader = DomainCutover::Credentials.method(:op_read))
      require_relative "op_vaults"
      fields = { access_key_id: "access-key-id", secret_access_key: "secret-access-key", endpoint: "endpoint" }
      values = fields.transform_values { |field| reader.call(OpVaults.ref(item, field), OpVaults.op_env) }
      empty = values.select { |_k, v| v.to_s.empty? }.keys
      raise Abort, "#{item} read empty (#{empty.join(', ')}): nothing was uploaded" if empty.any?

      values
    end
  end

  # Build, upload, mark, smoke. Raises Abort on the first failure, naming it.
  class Deploy
    Result = Struct.new(:files, :bytes, :keys, keyword_init: true)

    def initialize(target:, workspace:, sha:, uploader:, runner:, http:, say: ->(_line) { },
                   smoke_tries: 12, smoke_delay: 5, sleeper: ->(s) { sleep s }, clock: -> { Time.now.utc })
      @target = target
      @workspace = workspace
      @sha = sha.to_s
      @uploader = uploader
      @runner = runner
      @http = http
      @say = say
      @smoke_tries = smoke_tries
      @smoke_delay = smoke_delay
      @sleeper = sleeper
      @clock = clock
    end

    attr_reader :workspace

    def call
      result = publish!
      smoke!
      result
    end

    # Build, upload and mark, with no smoke: Downgrade smokes only after the host
    # points at the bucket.
    def publish!
      raise Abort, "no frozen SHA to deploy" if @sha.empty?

      build!
      items = Bundle.items(File.join(@workspace, @target.build_dir))
      upload!(items)
      write_marker!(items)
      files = items.map(&:path).uniq
      Result.new(files: files.size, bytes: files.sum { |f| File.size(f) }, keys: items.size + 1)
    end

    def build!
      @say.call("static build: (cd ship workspace) #{@target.build_command} → #{@target.build_dir}")
      out, ok = @runner.call([@target.build_command],
                             { "OUT" => File.join(@workspace, @target.build_dir), "HOST" => @target.host },
                             @workspace)
      raise Abort, "static build failed for #{@target.repo} (#{@target.build_command}):\n#{tail(out)}" unless ok
    end

    def upload!(items)
      @say.call("upload: #{items.size} object(s) → r2://#{@target.bucket} (assets first, then pages)")
      items.each_with_index do |item, index|
        ok, out = @uploader.put(@target.bucket, item)
        next if ok

        raise Abort, "upload failed at #{item.key} (#{index} of #{items.size} written; every key not yet " \
                     "written still serves the previous release, and no page names an asset it lacks): #{tail(out)}"
      end
    end

    def write_marker!(items)
      body = JSON.generate("sha" => @sha, "repo" => @target.repo, "built_at" => @clock.call.iso8601,
                           "objects" => items.size)
      path = File.join(@workspace, @target.build_dir + ".#{MARKER}")
      File.write(path, body)
      item = Item.new(key: MARKER, path: path, content_type: CONTENT_TYPES["json"], cache_control: CACHE_MARKER)
      ok, out = @uploader.put(@target.bucket, item)
      raise Abort, "upload failed at #{MARKER} (the pages are up; the ship cannot prove which SHA they are): #{tail(out)}" unless ok
    end

    # /up must answer 200 AND the marker must name the frozen SHA: a host still
    # pointing at the old Heroku dyno answers /up too, so /up alone proves nothing.
    def smoke!(tries: @smoke_tries, delay: @smoke_delay)
      @say.call("smoke: GET #{@target.smoke_url}/up and #{@target.smoke_url}/#{MARKER} (sha #{@sha[0, 8]})")
      last = ""
      tries.times do |attempt|
        up = @http.call(:get, "#{@target.smoke_url}/up")
        marker = @http.call(:get, "#{@target.smoke_url}/#{MARKER}")
        sha = marker.status == 200 ? marker.json["sha"].to_s : ""
        return if up.status == 200 && sha == @sha

        last = "/up → #{up.status}, #{MARKER} → #{marker.status}#{sha.empty? ? '' : " sha #{sha[0, 8]}"}"
        @sleeper.call(delay) if attempt < tries - 1
      end
      raise Abort, "smoke failed for #{@target.repo}: #{last} (wanted 200 and sha #{@sha[0, 8]})"
    rescue DomainCutover::Abort => e
      raise Abort, "smoke failed for #{@target.repo}: #{e.message}"
    end

    private

    def tail(out) = out.to_s.lines.last(15).join.strip
  end

  # The one-time move off Heroku. Plans the Cloudflare and Heroku writes, prints
  # them, and performs them only with execute: true. Order is the safety:
  #   1. the bucket exists and holds the site (a Deploy, minus its smoke)
  #   2. the host swap: the old DNS record goes, the R2 custom domain is attached,
  #      the URL rewrite is put (the only window where the host may not answer)
  #   3. smoke: /up and the marker at the frozen SHA, from Cloudflare, with a
  #      budget long enough for a new custom domain to activate
  #   4. only after a green smoke: the Heroku web dyno to 0. The app is kept at
  #      0 dynos for 30 days after the cutover, then deleted (Alex's ruling; the
  #      runbook records the date and who deletes it)
  # A failure anywhere in 2 or 3 rolls the host swap back in reverse (put the
  # zone's prior rewrite rules back, detach the custom domain, re-create each
  # deleted record), then raises with what the rollback did and the full manual
  # undo, so the host returns to Heroku and the dyno, never scaled, still serves.
  class Downgrade
    def initialize(target:, cloudflare:, heroku:, deploy:, say: ->(_line) { }, execute: false, scale_heroku: true,
                   smoke_tries: 60, smoke_delay: 10)
      @target = target
      @cf = cloudflare
      @heroku = heroku
      @deploy = deploy
      @say = say
      @execute = execute
      @scale_heroku = scale_heroku
      @smoke_tries = smoke_tries
      @smoke_delay = smoke_delay
      @undo = {}.compare_by_identity
    end

    # The writes, in order, as printable DomainCutover::Write values. Reads only.
    def plan
      zone = zone!
      writes = []
      writes << create_bucket unless bucket_exists?
      # Once the custom domain is attached, the host's record is the one R2
      # manages: a re-run must never plan to delete it.
      attached = domain_attached?
      existing = attached ? [] : host_records(zone["id"])
      existing.each { |rec| writes << delete_record(zone["id"], rec) }
      writes << attach_domain(zone["id"]) unless attached
      writes << url_rewrite(zone["id"])
      writes << scale_to_zero if @scale_heroku && !@target.heroku_app.empty?
      [writes, existing]
    end

    def call
      writes, existing = plan
      @say.call("downgrade #{@target.repo} → r2://#{@target.bucket} at #{@target.host}#{@execute ? '' : ' (PLAN ONLY: nothing is written)'}")
      writes.each { |w| @say.call("  #{w}") }
      existing.each { |rec| @say.call("  to undo the DNS step: re-create #{rec['type']} #{rec['name']} → #{rec['content']} (proxied: #{rec['proxied']})") }
      return writes unless @execute

      scale, before = writes.partition { |w| w.api == :heroku }
      bucket, swap = before.partition { |w| w.path.end_with?("/r2/buckets") }
      bucket.each { |w| @cf.perform(w) }
      @deploy.publish!
      swap_and_smoke!(swap)
      scale.each { |w| @heroku.perform(w) }
      writes
    end

    # The undo of one host-swap write, or nil for a write with none (the bucket
    # and the scale are never undone: an idle bucket costs nothing, and the scale
    # runs only after a green smoke).
    def undo_for(write) = @undo[write]

    def create_bucket
      DomainCutover::Write.new(api: :cloudflare, verb: :post, path: "/accounts/#{@cf.account_id}/r2/buckets",
                               body: { "name" => @target.bucket }, why: "the bucket the site is served from")
    end

    def delete_record(zone_id, rec)
      write = DomainCutover::Write.new(api: :cloudflare, verb: :delete, path: "/zones/#{zone_id}/dns_records/#{rec['id']}",
                                       why: "#{rec['type']} #{rec['name']} → #{rec['content']} is the Heroku route; " \
                                            "the R2 custom domain needs the name free")
      body = rec.slice("type", "name", "content", "proxied", "ttl").compact
      @undo[write] = DomainCutover::Write.new(api: :cloudflare, verb: :post, path: "/zones/#{zone_id}/dns_records",
                                              body: body, why: "re-create #{rec['type']} #{rec['name']} → #{rec['content']}")
      write
    end

    def attach_domain(zone_id)
      path = "/accounts/#{@cf.account_id}/r2/buckets/#{@target.bucket}/domains/custom"
      write = DomainCutover::Write.new(api: :cloudflare, verb: :post, path: path,
                                       body: { "domain" => @target.host, "zoneId" => zone_id, "enabled" => true, "minTLS" => "1.2" },
                                       why: "serve #{@target.host} from the bucket (a proxied record Cloudflare manages)")
      @undo[write] = DomainCutover::Write.new(api: :cloudflare, verb: :delete, path: "#{path}/#{@target.host}",
                                              why: "detach #{@target.host} from r2://#{@target.bucket}, freeing the name")
      write
    end

    # The index-document rewrite (Rewrite.rules). A PUT on the phase entrypoint
    # replaces the whole list, so the zone's other rewrites (other apps' hosts)
    # are carried as they are, and a re-run replaces ours by ref. Its undo puts
    # back the list exactly as it was read.
    def url_rewrite(zone_id)
      ours = Rewrite.rules(@target.host)
      refs = ours.map { |r| r["ref"] }
      prior = @cf.transform_rules(zone_id).map { |r| r.slice("id", "ref", "description", "expression", "action", "action_parameters", "enabled") }
      carried = prior.reject { |r| refs.include?(r["ref"]) }
      path = "/zones/#{zone_id}/rulesets/phases/#{REWRITE_PHASE}/entrypoint"
      write = DomainCutover::Write.new(api: :cloudflare, verb: :put, path: path, body: { "rules" => carried + ours },
                                       why: "#{@target.host}: /x and /x/ serve x/index.html (URL rewrite, address bar unchanged)")
      @undo[write] = DomainCutover::Write.new(api: :cloudflare, verb: :put, path: path, body: { "rules" => prior },
                                              why: "put the zone's #{prior.size} prior rewrite rule(s) back, without #{@target.host}'s")
      write
    end

    def scale_to_zero
      DomainCutover::Write.new(api: :heroku, verb: :patch, path: "/apps/#{@target.heroku_app}/formation/web",
                               body: { "quantity" => 0 },
                               why: "#{@target.heroku_app} web to 0: kept at 0 dynos for 30 days after the cutover, then deleted")
    end

    private

    # Steps 2 and 3, with the rollback. Every write is attempted in order; the
    # first failure (or a red smoke) undoes the writes that landed, newest first.
    def swap_and_smoke!(swap)
      done = []
      begin
        swap.each do |w|
          @cf.perform(w)
          done << w
        end
        @deploy.smoke!(tries: @smoke_tries, delay: @smoke_delay)
      rescue StandardError => e
        raise Abort, rollback_message(e, done, swap)
      end
    end

    def rollback_message(error, done, swap)
      @say.call("rollback: #{error.message.lines.first.to_s.strip}; undoing #{done.size} host write(s), newest first")
      results = done.reverse.map do |w|
        undo = @undo.fetch(w)
        begin
          @cf.perform(undo)
          "  undone: #{undo}"
        rescue StandardError => e
          "  UNDO FAILED: #{undo}\n    #{e.message}"
        end
      end
      results.each { |line| @say.call(line) }
      clean = results.none? { |line| line.include?("UNDO FAILED") }
      <<~TEXT.strip
        #{@target.repo}: the host swap failed and was rolled back#{clean ? '' : ' INCOMPLETELY'}: #{error.message}
        The Heroku dyno was not scaled; r2://#{@target.bucket} is left in place (it serves nothing once detached).
        Rollback, newest first:
        #{results.empty? ? '  (nothing had been written)' : results.join("\n")}
        Full manual undo, newest first, if any line above failed (each is idempotent to check by eye in the dashboard):
        #{swap.reverse.map { |w| "  #{@undo.fetch(w)}" }.join("\n")}
        Then confirm #{@target.smoke_url}/up answers from Heroku again.
      TEXT
    end

    # The zone that holds the host: the longest zone name the host ends with.
    def zone!
      labels = @target.host.split(".")
      (0...(labels.size - 1)).each do |i|
        zone = @cf.find_zone(labels[i..].join("."))
        return zone if zone
      end
      raise Abort, "no Cloudflare zone in this account holds #{@target.host}"
    end

    def bucket_exists?
      @cf.raw(:get, "/accounts/#{@cf.account_id}/r2/buckets/#{@target.bucket}", allow: [404]).any?
    end

    def domain_attached?
      body = @cf.raw(:get, "/accounts/#{@cf.account_id}/r2/buckets/#{@target.bucket}/domains/custom", allow: [404])
      Array(body.dig("result", "domains")).any? { |d| d["domain"] == @target.host }
    end

    def host_records(zone_id)
      body = @cf.raw(:get, "/zones/#{zone_id}/dns_records?#{URI.encode_www_form('name' => @target.host)}")
      Array(body["result"]).select { |r| %w[A AAAA CNAME].include?(r["type"]) && r["name"] == @target.host }
    end
  end

  # DomainCutover's Cloudflare client plus the one raw read Downgrade needs.
  class CloudflareApi < DomainCutover::Cloudflare
    def raw(verb, path, allow: []) = request(verb, path, nil, allow: allow)

    # The URL-rewrite phase's rules, or [] when the zone has none yet (404).
    def transform_rules(zone_id)
      body = request(:get, "/zones/#{zone_id}/rulesets/phases/#{REWRITE_PHASE}/entrypoint", nil, allow: [404])
      Array(body.dig("result", "rules"))
    end
  end
end
