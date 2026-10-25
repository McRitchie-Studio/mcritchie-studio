# frozen_string_literal: true

# deploy_app's static_cloudflare adapter: a ship of a fixture app through the
# strategy against a stub R2 bucket (docs/agents/modules/static-cloudflare.md).
#
# Part of the bin/release CLI suite; the shared subprocess harness lives in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_static_cloudflare_test.rb

require_relative "release_cli_harness"
require_relative "../../bin/lib/static_cloudflare"

class ReleaseCliStaticCloudflareTest < ReleaseCliHarness
  # --- static_cloudflare: an app served as plain files from R2 -----------------

  # A stub R2 bucket for the CLI subprocess: each object is a file named by its
  # escaped key, and the HTTP stub serves them the way the zone's URL rewrite and
  # an R2 custom domain do (StaticCloudflare::Rewrite.key_for).
  STATIC_STUB = <<~'RUBY'
    STUB_DIR = ENV.fetch("STATIC_STUB_DIR")
    STUB_FAIL_AT = ENV["STATIC_STUB_FAIL_AT"].to_s
    class StubBucket
      def put(bucket, item)
        File.open(File.join(STUB_DIR, "puts.log"), "a") { |f| f.puts("#{bucket} #{item.key} #{item.content_type}") }
        return [false, "An error occurred (AccessDenied) on #{item.key}"] if item.key == STUB_FAIL_AT

        File.binwrite(File.join(STUB_DIR, item.key.gsub("/", "%2F")), File.binread(item.path))
        [true, ""]
      end
    end
    def static_cloudflare_uploader(_target) = StubBucket.new
    def static_cloudflare_http
      lambda do |_verb, url, headers: {}, body: nil|
        file = File.join(STUB_DIR, StaticCloudflare::Rewrite.key_for(URI(url).path).gsub("/", "%2F"))
        DomainCutover::Response.new(status: File.file?(file) ? 200 : 404, body: File.file?(file) ? File.read(file) : "")
      end
    end
    def repo_path(_repo) = REPO_UNDER_TEST
    def record_merged_main(_s); end
  RUBY

  # The fixture app's own bin/static-build, COMMITTED at the frozen SHA so it lands
  # in the ship workspace. It writes the minimum site the strategy requires, and
  # puts its cwd and HEAD into the home page so the test can read where it ran.
  def plant_static_build(clone)
    script = File.join(clone, "bin", "static-build")
    File.write(script, <<~SH)
      #!/usr/bin/env sh
      set -eu
      mkdir -p "$OUT/up" "$OUT/rants/x" "$OUT/assets"
      printf 'cwd=%s head=%s host=%s rails_env=%s' "$(pwd)" "$(git rev-parse HEAD)" "$HOST" "${RAILS_ENV:-unset}" > "$OUT/index.html"
      printf '<body>ok</body>' > "$OUT/up/index.html"
      printf '<h1>x</h1>' > "$OUT/rants/x/index.html"
      printf 'body{}' > "$OUT/assets/app-1a2b3c4d.css"
    SH
    File.chmod(0o755, script)
    run_git(clone, "add", ".")
    run_git(clone, "commit", "-q", "-m", "static build")
    run_git(clone, "branch", "-f", "release")
    run_git(clone, "push", "-q", "-f", "origin", "release")
    git_out(clone, "rev-parse", "release")
  end

  def static_group
    %({ "repo" => "sibling", "members" => [],
        "prod_deploy" => { "strategy" => "static_cloudflare", "bucket" => "mcr-rantly-static",
                           "smoke_url" => "https://rantly.mcritchie.studio", "heroku_app" => "mcr-rantly" } })
  end

  def run_static_deploy(dir, clone, frozen, argv: ["--yes"], fail_at: nil)
    stub = File.join(dir, "bucket")
    FileUtils.mkdir_p(stub)
    env_setup = %(ENV["STATIC_STUB_DIR"] = #{stub.inspect}; ENV["STATIC_STUB_FAIL_AT"] = #{fail_at.to_s.inspect}\n) +
                %(REPO_UNDER_TEST = #{clone.inspect}\n) + STATIC_STUB
    # abort! exits: catch it in the child and fold stderr into stdout, so the
    # abort's message is the assertion (as the unknown-strategy test does).
    call = %{$stderr = $stdout; begin; deploy_app(#{static_group}, #{frozen.inspect}); puts("PASSED"); } +
           %{rescue SystemExit; puts("ABORTED"); end}
    out = run_cli(argv, setup: env_setup, call: call)
    [out, stub]
  end

  def stub_object(stub, key) = File.read(File.join(stub, key.gsub("/", "%2F")))

  # [integration] rantly's ship through the new strategy, against a stub bucket:
  # the build runs in the SHIP workspace at the frozen SHA (never the dirty
  # primary), every object lands, the marker names the SHA, and the smoke reads it
  # back from the "host" before the ship records a production deploy.
  def test_deploy_app_static_cloudflare_builds_at_the_frozen_sha_uploads_and_smokes
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      frozen = plant_static_build(clone)
      run_git(clone, "checkout", "-q", "-b", "feat/live-session")
      File.write(File.join(clone, "app.rb"), "half a feature")

      out, stub = run_static_deploy(dir, clone, frozen)

      assert_includes out, "PASSED", "the static deploy must complete: #{out}"
      home = stub_object(stub, "index.html")
      assert_includes home, ".worktrees/_ship", "the build runs in the SHIP workspace: #{home}"
      assert_includes home, "head=#{frozen}", "…at the frozen SHA"
      assert_includes home, "host=rantly.mcritchie.studio"
      assert_includes home, "rails_env=unset", "a production render: never the gate's RAILS_ENV=test"
      assert_equal "<h1>x</h1>", stub_object(stub, "rants/x/index.html")
      assert_equal frozen, JSON.parse(stub_object(stub, StaticCloudflare::MARKER))["sha"]
      log = File.readlines(File.join(stub, "puts.log"), chomp: true)
      assert(log.all? { |l| l.start_with?("mcr-rantly-static ") }, "every object goes to the adapter's bucket")
      assert_equal StaticCloudflare::MARKER, log.last.split[1], "the marker is written last"
      assert_equal frozen, git_out(File.join(dir, "origin.git"), "rev-parse", "main"), "origin/main advanced"
      assert_equal "feat/live-session", git_out(clone, "rev-parse", "--abbrev-ref", "HEAD"), "the primary is never checked out"
    end
  end

  # [integration] a failed upload ABORTS the ship, names the key, and writes no
  # marker, so finalize can never read the half-uploaded release as live.
  def test_deploy_app_static_cloudflare_aborts_on_a_failed_upload
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      frozen = plant_static_build(clone)

      out, stub = run_static_deploy(dir, clone, frozen, fail_at: "rants/x/index.html")

      refute_includes out, "PASSED", "a failed upload must abort the ship: #{out}"
      assert_includes out, "ABORTED"
      assert_match(%r{static deploy failed for sibling: upload failed at rants/x/index\.html}, out)
      assert_includes out, "AccessDenied"
      refute File.exist?(File.join(stub, StaticCloudflare::MARKER)), "no marker after a failed upload"
    end
  end

  # [integration] the DRY-RUN ship of rantly: the plan names the build, the bucket
  # and the smoke, and nothing is built or uploaded.
  def test_deploy_app_static_cloudflare_dry_run_builds_and_uploads_nothing
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      frozen = plant_static_build(clone)

      out, stub = run_static_deploy(dir, clone, frozen, argv: ["--dry-run", "--yes"])

      assert_includes out, "PASSED", out
      assert_includes out, "bin/static-build @ #{frozen[0, 7]} → r2://mcr-rantly-static → smoke https://rantly.mcritchie.studio/up"
      assert_includes out, "nothing uploaded"
      refute File.exist?(File.join(stub, "puts.log")), "a dry run uploads nothing"
    end
  end

  # [integration] an adapter with no bucket is refused before anything is built.
  def test_deploy_app_static_cloudflare_refuses_an_adapter_with_no_bucket
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      frozen = git_out(clone, "rev-parse", "release")
      group = %({ "repo" => "sibling", "members" => [],
                  "prod_deploy" => { "strategy" => "static_cloudflare", "smoke_url" => "https://x.test" } })
      setup = %(def repo_path(_repo) = #{clone.inspect}\ndef record_merged_main(s); puts("STAMPED-MAIN"); end\n)
      call = %{$stderr = $stdout; begin; deploy_app(#{group}, #{frozen.inspect}); puts("PASSED"); } +
             %{rescue SystemExit; puts("ABORTED"); end}
      out = run_cli(["--yes"], setup: setup, call: call)
      refute_includes out, "PASSED"
      assert_includes out, "static_cloudflare adapter names no `bucket`"
      refute_includes out, "STAMPED-MAIN", "refused BEFORE push_frozen_main moves anything"
    end
  end
end
