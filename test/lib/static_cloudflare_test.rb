# frozen_string_literal: true

# [unit] StaticCloudflare (bin/lib/static_cloudflare.rb): the target read from a
# prod_deploy adapter, the bundle's keys and headers, the aws upload argv, and the
# Deploy and Downgrade units with every subprocess and HTTP call faked.
#
#   ruby -Itest test/lib/static_cloudflare_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/static_cloudflare"

class StaticCloudflareTest < Minitest::Test
  SC = StaticCloudflare
  SHA = "0123456789abcdef0123456789abcdef01234567"
  ADAPTER = { "strategy" => "static_cloudflare", "bucket" => "mcr-rantly-static",
              "smoke_url" => "https://rantly.mcritchie.studio", "heroku_app" => "mcr-rantly" }.freeze

  # A fake R2 bucket: put writes into a hash; `fail_at` makes one key refuse.
  class Bucket
    attr_reader :objects, :puts

    def initialize(fail_at: nil)
      @objects = {}
      @puts = []
      @fail_at = fail_at
    end

    def put(bucket, item)
      @puts << [bucket, item.key]
      return [false, "An error occurred (AccessDenied)"] if item.key == @fail_at

      @objects[item.key] = { body: File.binread(item.path), type: item.content_type, cache: item.cache_control }
      [true, ""]
    end
  end

  # Serves the fake bucket over "HTTP" the way the zone's URL rewrite plus an R2
  # custom domain do: the key Rewrite.key_for names, else 404.
  class Edge
    def initialize(bucket, up_status: nil)
      @bucket = bucket
      @up_status = up_status
    end

    def call(_verb, url, headers: {}, body: nil)
      key = SC::Rewrite.key_for(URI(url).path)
      return DomainCutover::Response.new(status: @up_status, body: "") if @up_status && key == "up/index.html"

      object = @bucket.objects[key]
      object ? DomainCutover::Response.new(status: 200, body: object[:body]) : DomainCutover::Response.new(status: 404, body: "")
    end
  end

  def target = SC::Target.from("rantly", ADAPTER)

  # A workspace whose build command writes a small site into OUT.
  def with_workspace(site: default_site, build_ok: true)
    Dir.mktmpdir do |ws|
      runner = lambda do |argv, env, chdir|
        @build = { argv: argv, env: env, chdir: chdir }
        next ["boom: assets:precompile failed", false] unless build_ok

        site.each do |path, body|
          file = File.join(env.fetch("OUT"), path)
          FileUtils.mkdir_p(File.dirname(file))
          File.write(file, body)
        end
        ["static: #{site.size} files", true]
      end
      yield ws, runner
    end
  end

  def default_site
    { "index.html" => "<a href=/rants/x>x</a>", "up/index.html" => "<body>ok</body>",
      "rants/x/index.html" => "<h1>x</h1>", "assets/app-1a2b3c4d.css" => "body{}", "icon.svg" => "<svg/>" }
  end

  def deploy(ws, runner, bucket, http: Edge.new(bucket), tries: 2)
    SC::Deploy.new(target: target, workspace: ws, sha: SHA, uploader: bucket, runner: runner, http: http,
                   smoke_tries: tries, sleeper: ->(_s) {}, clock: -> { Time.utc(2026, 10, 25) })
  end

  # ── Target ────────────────────────────────────────────────────────────────
  def test_target_reads_the_adapter_and_defaults_the_build
    t = target
    assert_equal "rantly.mcritchie.studio", t.host
    assert_equal "mcr-rantly-static", t.bucket
    assert_equal "bin/static-build", t.build_command
    assert_equal "tmp/static/site", t.build_dir
    assert_equal "r2.static-sites", t.credential
  end

  def test_target_refuses_an_adapter_with_no_bucket_or_smoke_url
    assert_raises(SC::Abort) { SC::Target.from("rantly", ADAPTER.merge("bucket" => "")) }
    error = assert_raises(SC::Abort) { SC::Target.from("rantly", ADAPTER.except("smoke_url")) }
    assert_match(/smoke_url/, error.message)
  end

  # ── Bundle ────────────────────────────────────────────────────────────────
  def test_bundle_writes_assets_before_pages_and_one_key_per_file
    Dir.mktmpdir do |dir|
      default_site.each { |p, b| FileUtils.mkdir_p(File.dirname(File.join(dir, p))); File.write(File.join(dir, p), b) }
      items = SC::Bundle.items(dir)
      assert_equal default_site.keys.sort, items.map(&:key).sort, "one object per file: the rewrite, not a copy, serves /x"
      pages = items.each_index.select { |i| items[i].content_type.start_with?("text/html") }
      assets = items.each_index.reject { |i| items[i].content_type.start_with?("text/html") }
      assert_operator assets.max, :<, pages.min, "every asset is written before any page"
    end
  end

  # ── Rewrite ───────────────────────────────────────────────────────────────
  def test_rewrite_maps_each_path_shape_to_its_key
    {
      "/" => "index.html", "" => "index.html", "/up" => "up/index.html", "/rants/x" => "rants/x/index.html",
      "/rants/x/" => "rants/x/index.html", "/@rantly" => "@rantly/index.html",
      "/assets/app-1a2b3c4d.css" => "assets/app-1a2b3c4d.css", "/404.html" => "404.html",
      "/static-release.json" => "static-release.json"
    }.each { |path, key| assert_equal key, SC::Rewrite.key_for(path), path }
  end

  # The two rules ARE key_for, written in Cloudflare's rule language. Each branch
  # of key_for has its rule, with only all-plan functions (no regex, no matches).
  def test_rewrite_rules_encode_key_for_on_the_one_host
    dir, page = SC::Rewrite.rules("rantly.mcritchie.studio")
    assert_equal %((http.host eq "rantly.mcritchie.studio" and ends_with(http.request.uri.path, "/"))), dir["expression"]
    assert_equal %(concat(http.request.uri.path, "index.html")), dir.dig("action_parameters", "uri", "path", "expression")
    assert_includes page["expression"], %(not http.request.uri.path contains ".")
    assert_includes page["expression"], %(not ends_with(http.request.uri.path, "/"))
    assert_equal %(concat(http.request.uri.path, "/index.html")), page.dig("action_parameters", "uri", "path", "expression")
    assert_equal %w[rewrite rewrite], [dir["action"], page["action"]]
    refute_match(/matches|regex/, dir["expression"] + page["expression"])
    refute_equal dir["ref"], page["ref"]
  end

  def test_bundle_sets_the_cache_policy_by_kind
    Dir.mktmpdir do |dir|
      default_site.each { |p, b| FileUtils.mkdir_p(File.dirname(File.join(dir, p))); File.write(File.join(dir, p), b) }
      by_key = SC::Bundle.items(dir).to_h { |i| [i.key, i] }
      assert_equal SC::CACHE_PAGE, by_key["rants/x/index.html"].cache_control
      assert_equal SC::CACHE_DIGESTED, by_key["assets/app-1a2b3c4d.css"].cache_control
      assert_equal SC::CACHE_OTHER, by_key["icon.svg"].cache_control
      assert_equal "text/css; charset=utf-8", by_key["assets/app-1a2b3c4d.css"].content_type
    end
  end

  def test_bundle_refuses_a_missing_up_an_unknown_extension_and_a_symlink
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "index.html"), "x")
      assert_match(%r{up/index\.html}, assert_raises(SC::Abort) { SC::Bundle.items(dir) }.message)

      FileUtils.mkdir_p(File.join(dir, "up"))
      File.write(File.join(dir, "up/index.html"), "ok")
      File.write(File.join(dir, "notes.rb"), "puts 1")
      assert_match(/no Content-Type for \.rb/, assert_raises(SC::Abort) { SC::Bundle.items(dir) }.message)

      File.delete(File.join(dir, "notes.rb"))
      File.symlink("/etc/hosts", File.join(dir, "hosts.txt"))
      assert_match(/symlink/, assert_raises(SC::Abort) { SC::Bundle.items(dir) }.message)
    end
  end

  # ── S3Uploader ────────────────────────────────────────────────────────────
  def test_uploader_puts_one_object_with_its_headers_and_keeps_the_keys_out_of_argv
    seen = nil
    creds = { access_key_id: "AKIDEXAMPLE123", secret_access_key: "s3cr3t-value-xyz", endpoint: "https://acct.r2.cloudflarestorage.com" }
    runner = ->(argv, env) { seen = [argv, env]; ["denied for s3cr3t-value-xyz", false] }
    item = SC::Item.new(key: "rants/x", path: "/tmp/x.html", content_type: "text/html; charset=utf-8", cache_control: "no-cache")
    ok, out = SC::S3Uploader.new(creds, runner: runner).put("mcr-rantly-static", item)

    argv, env = seen
    assert_equal %w[aws s3api put-object], argv.first(3)
    assert_equal "rants/x", argv[argv.index("--key") + 1]
    assert_equal "text/html; charset=utf-8", argv[argv.index("--content-type") + 1]
    assert_equal "no-cache", argv[argv.index("--cache-control") + 1]
    assert_equal "https://acct.r2.cloudflarestorage.com", argv[argv.index("--endpoint-url") + 1]
    refute(argv.any? { |a| a.include?("s3cr3t") || a.include?("AKIDEXAMPLE") }, "keys ride in env, never argv")
    assert_equal "auto", env["AWS_DEFAULT_REGION"]
    refute ok
    refute_includes out, "s3cr3t-value-xyz", "an error echo is redacted"
  end

  # ── Deploy ────────────────────────────────────────────────────────────────
  def test_deploy_builds_in_the_workspace_uploads_marks_and_smokes
    with_workspace do |ws, runner|
      bucket = Bucket.new
      result = deploy(ws, runner, bucket).call

      assert_equal ["bin/static-build"], @build[:argv]
      assert_equal ws, @build[:chdir], "the build runs in the ship workspace at the frozen SHA"
      assert_equal "rantly.mcritchie.studio", @build[:env]["HOST"]
      assert_equal "mcr-rantly-static", bucket.puts.first.first
      assert_equal SC::MARKER, bucket.puts.last.last, "the marker is written last"
      marker = JSON.parse(bucket.objects[SC::MARKER][:body])
      assert_equal SHA, marker["sha"]
      assert_equal SC::CACHE_MARKER, bucket.objects[SC::MARKER][:cache]
      assert_equal 5, result.files
      assert_equal "<h1>x</h1>", bucket.objects["rants/x/index.html"][:body]
    end
  end

  def test_deploy_aborts_on_a_failed_build_and_uploads_nothing
    with_workspace(build_ok: false) do |ws, runner|
      bucket = Bucket.new
      error = assert_raises(SC::Abort) { deploy(ws, runner, bucket).call }
      assert_match(/static build failed for rantly.*assets:precompile failed/m, error.message)
      assert_empty bucket.puts
    end
  end

  def test_deploy_aborts_on_a_failed_upload_names_the_key_and_writes_no_marker
    with_workspace do |ws, runner|
      bucket = Bucket.new(fail_at: "rants/x/index.html")
      error = assert_raises(SC::Abort) { deploy(ws, runner, bucket).call }
      assert_match(%r{upload failed at rants/x/index\.html}, error.message)
      assert_match(/AccessDenied/, error.message)
      refute bucket.objects.key?(SC::MARKER), "no marker: the ship must not read this release as live"
      refute(bucket.puts.any? { |_b, key| key == "up/index.html" }, "nothing after the failed key is written")
    end
  end

  def test_deploy_aborts_when_the_marker_upload_fails
    with_workspace do |ws, runner|
      error = assert_raises(SC::Abort) { deploy(ws, runner, Bucket.new(fail_at: SC::MARKER)).call }
      assert_match(/upload failed at #{Regexp.escape(SC::MARKER)}/, error.message)
    end
  end

  def test_smoke_needs_the_marker_at_the_frozen_sha_not_just_up
    with_workspace do |ws, runner|
      bucket = Bucket.new
      stale = Object.new
      stale.define_singleton_method(:call) do |_verb, url, headers: {}, body: nil|
        if url.end_with?("/up")
          DomainCutover::Response.new(status: 200, body: "")
        else
          DomainCutover::Response.new(status: 200, body: JSON.generate("sha" => "f" * 40))
        end
      end
      error = assert_raises(SC::Abort) { deploy(ws, runner, bucket, http: stale).call }
      assert_match(/smoke failed for rantly: .*sha ffffffff/, error.message,
                   "the old Heroku dyno answers /up too, so /up alone must never pass the smoke")
    end
  end

  def test_smoke_fails_on_a_non_200_up
    with_workspace do |ws, runner|
      bucket = Bucket.new
      error = assert_raises(SC::Abort) { deploy(ws, runner, bucket, http: Edge.new(bucket, up_status: 503)).call }
      assert_match(%r{/up → 503}, error.message)
    end
  end

  def test_smoke_retries_until_the_edge_serves_the_new_release
    with_workspace do |ws, runner|
      bucket = Bucket.new
      edge = Edge.new(bucket)
      calls = 0
      flaky = lambda do |verb, url, headers: {}, body: nil|
        calls += 1
        calls <= 2 ? DomainCutover::Response.new(status: 404, body: "") : edge.call(verb, url)
      end
      deploy(ws, runner, bucket, http: flaky, tries: 3).call
      assert_equal 4, calls, "one failed pair, then one good pair"
    end
  end

  # ── Downgrade ─────────────────────────────────────────────────────────────
  # A Cloudflare API stand-in: canned reads, recorded writes.
  class FakeCloudflare
    attr_reader :account_id, :performed

    def initialize(attached: false, bucket: false, rules: [])
      @account_id = "acct123"
      @attached = attached
      @bucket = bucket
      @rules = rules
      @performed = []
    end

    def find_zone(name) = name == "mcritchie.studio" ? { "id" => "zone1", "name" => name } : nil
    def transform_rules(_zone) = @rules
    def perform(write) = (@performed << write) && {}

    def raw(_verb, path, allow: [])
      case path
      when %r{/domains/custom\z} then { "result" => { "domains" => @attached ? [{ "domain" => "rantly.mcritchie.studio" }] : [] } }
      when %r{/r2/buckets/[^/]+\z} then @bucket ? { "result" => { "name" => "mcr-rantly-static" } } : {}
      when /dns_records/
        { "result" => [{ "id" => "rec9", "type" => "CNAME", "name" => "rantly.mcritchie.studio",
                         "content" => "elementary-falls.herokudns.com", "proxied" => false }] }
      else raise "unexpected read #{path}"
      end
    end
  end

  class FakeHeroku
    attr_reader :performed

    def initialize = @performed = []
    def perform(write) = @performed << write
  end

  def downgrade(cf, heroku, deploy, execute:, lines: [])
    SC::Downgrade.new(target: target, cloudflare: cf, heroku: heroku, deploy: deploy,
                      say: ->(l) { lines << l }, execute: execute)
  end

  def test_downgrade_plans_bucket_dns_domain_root_and_scale_in_order
    writes, existing = downgrade(FakeCloudflare.new, FakeHeroku.new, nil, execute: false).plan
    assert_equal [
      [:post, "/accounts/acct123/r2/buckets"],
      [:delete, "/zones/zone1/dns_records/rec9"],
      [:post, "/accounts/acct123/r2/buckets/mcr-rantly-static/domains/custom"],
      [:put, "/zones/zone1/rulesets/phases/http_request_transform/entrypoint"],
      [:patch, "/apps/mcr-rantly/formation/web"]
    ], writes.map { |w| [w.verb, w.path] }
    assert_equal({ "quantity" => 0 }, writes.last.body)
    assert_equal "elementary-falls.herokudns.com", existing.first["content"]
  end

  def test_downgrade_url_rewrite_carries_the_zones_other_rules_and_replaces_its_own
    other = { "id" => "r1", "ref" => "static_cloudflare_dads_app_com_page", "expression" => "x", "action" => "rewrite",
              "enabled" => true, "version" => "3" }
    stale = { "id" => "r2", "ref" => "static_cloudflare_rantly_mcritchie_studio_page", "expression" => "old",
              "action" => "rewrite", "enabled" => true }
    writes, = downgrade(FakeCloudflare.new(rules: [other, stale]), FakeHeroku.new, nil, execute: false).plan
    rules = writes.find { |w| w.verb == :put }.body["rules"]
    assert_equal "static_cloudflare_dads_app_com_page", rules.first["ref"]
    refute rules.first.key?("version"), "only the writable fields are carried"
    refute(rules.any? { |r| r["expression"] == "old" }, "a re-run replaces this host's rules by ref")
    assert_equal SC::Rewrite.rules("rantly.mcritchie.studio"), rules.last(2)
  end

  def test_downgrade_rerun_after_attach_never_deletes_the_managed_record
    writes, = downgrade(FakeCloudflare.new(attached: true, bucket: true), FakeHeroku.new, nil, execute: false).plan
    refute(writes.any? { |w| w.verb == :delete }, "the attached domain's record is R2's; deleting it would take the site down")
    refute(writes.any? { |w| w.path.end_with?("/domains/custom") })
  end

  def test_downgrade_without_execute_prints_the_plan_and_writes_nothing
    cf = FakeCloudflare.new
    heroku = FakeHeroku.new
    lines = []
    downgrade(cf, heroku, :never_called, execute: false, lines: lines).call
    assert_empty cf.performed
    assert_empty heroku.performed
    assert_match(/PLAN ONLY/, lines.first)
    assert(lines.any? { |l| l.include?("re-create CNAME rantly.mcritchie.studio → elementary-falls.herokudns.com") },
           "the plan prints how to undo the DNS step")
  end

  def test_downgrade_execute_scales_heroku_only_after_a_green_smoke
    with_workspace do |ws, runner|
      bucket = Bucket.new
      cf = FakeCloudflare.new
      heroku = FakeHeroku.new
      downgrade(cf, heroku, deploy(ws, runner, bucket), execute: true).call
      assert_equal 4, cf.performed.size
      assert_equal ["/apps/mcr-rantly/formation/web"], heroku.performed.map(&:path)
      assert bucket.objects.key?(SC::MARKER)
    end
  end

  def test_downgrade_execute_with_a_failed_smoke_leaves_the_dyno_up
    with_workspace do |ws, runner|
      bucket = Bucket.new
      heroku = FakeHeroku.new
      dep = deploy(ws, runner, bucket, http: Edge.new(bucket, up_status: 522))
      assert_raises(SC::Abort) { downgrade(FakeCloudflare.new, heroku, dep, execute: true).call }
      assert_empty heroku.performed, "a host that does not answer from Cloudflare keeps its Heroku dyno"
    end
  end

  def test_downgrade_execute_with_a_failed_upload_touches_no_dns
    with_workspace do |ws, runner|
      cf = FakeCloudflare.new
      dep = deploy(ws, runner, Bucket.new(fail_at: "up/index.html"))
      assert_raises(SC::Abort) { downgrade(cf, FakeHeroku.new, dep, execute: true).call }
      assert_equal ["/accounts/acct123/r2/buckets"], cf.performed.map(&:path), "only the bucket was created"
    end
  end
end
