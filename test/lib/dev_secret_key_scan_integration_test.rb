# frozen_string_literal: true

# [integration] The digest scan, EXECUTED: bin/dev-secret-key run as a process over a
# projects tree laid out the way the machine is (primaries plus .worktrees desks),
# and bin/ecosystem-build's .env restore run against a stubbed `heroku` that answers
# with a production config.
#
# What the scan must do, and what each test pins:
#   * flag every local env file whose key matches a production digest, and only those
#   * never print a value, flagged or not
#   * `fix` leaves no file on a production key, and a re-scan proves it
#   * FAIL CLOSED: with no production digest to compare against, a scan that found
#     nothing proves nothing, so it exits 2 instead of 0
# and what a fresh-machine restore must do: write every config var EXCEPT the
# production key, and give the file a generated development one instead.
#
#   ruby -Itest test/lib/dev_secret_key_scan_integration_test.rb
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "digest"

class DevSecretKeyScanIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CLI = File.join(ROOT, "bin/dev-secret-key")
  ECOSYSTEM_BUILD = File.join(ROOT, "bin/ecosystem-build")

  PROD = "c0ffee" * 21 + "ab" # 128 hex; a stand-in, never a real key
  PROD_DIGEST = Digest::SHA256.hexdigest(PROD)
  DEV = "d" * 128

  # The machine's shape: two primaries and their desks, one desk already on a dev
  # key, one template with an empty value, one file that never set the key.
  LAYOUT = {
    "mcritchie-studio/.env" => "A=1\nSECRET_KEY_BASE=#{PROD}\n",
    "mcritchie-studio/.env.example" => "SECRET_KEY_BASE=                  # template\n",
    "mcritchie-studio/.worktrees/desk-one/.env" => "SECRET_KEY_BASE=#{PROD}\nB=2\n",
    "mcritchie-studio/.worktrees/desk-two/.env" => "SECRET_KEY_BASE=#{DEV}\n",
    "turf-monster/.env" => "export SECRET_KEY_BASE=\"#{PROD}\"\n",
    "turf-monster/.worktrees/desk-three/.env" => "SECRET_KEY_BASE=#{PROD}\n",
    "rolio/.env" => "C=3\n"
  }.freeze

  FLAGGED = %w[
    mcritchie-studio/.env
    mcritchie-studio/.worktrees/desk-one/.env
    turf-monster/.env
    turf-monster/.worktrees/desk-three/.env
  ].freeze

  def with_projects
    Dir.mktmpdir("dev-secret-key-scan") do |dir|
      LAYOUT.each do |rel, body|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      yield dir
    end
  end

  def cli(*args, env: {})
    out, err, status = Open3.capture3(env, "ruby", CLI, *args)
    [out, err, status.exitstatus]
  end

  def flagged_paths(out, dir)
    out.lines.grep(/PRODUCTION/).map { |l| l.split.first.delete_prefix("#{dir}/") }.sort
  end

  def test_scan_flags_exactly_the_files_on_a_production_key_and_prints_no_value
    with_projects do |dir|
      out, err, code = cli("scan", "--projects", dir, "--digest", PROD_DIGEST)

      assert_equal 1, code, "a production key on disk is a failing scan\n#{out}#{err}"
      assert_equal FLAGGED.sort, flagged_paths(out, dir)
      assert_includes out, PROD_DIGEST[0, 8], "a flagged row names the digest prefix"
      assert_match(%r{desk-two/\.env\s+\h{8}\s+dev}, out)
      assert_match(%r{\.env\.example\s+empty}, out)
      refute_includes out, "rolio/.env", "a file that never sets the key is not a row"
      [PROD, DEV].each { |v| refute_includes out + err, v, "no value is ever printed" }
      assert_match(/summary: 6 file\(s\) set the key, 4 hold a production key/, out)
    end
  end

  def test_fix_rewrites_every_flagged_file_and_a_rescan_is_clean
    with_projects do |dir|
      before = LAYOUT.keys.to_h { |rel| [rel, File.read(File.join(dir, rel))] }

      out, err, code = cli("fix", "--projects", dir, "--digest", PROD_DIGEST)
      assert_equal 0, code, "#{out}#{err}"
      assert_match(/4 held a production key, 4 rewritten, 0 still production/, out)
      refute_includes out + err, PROD

      rescan, _, rescan_code = cli("scan", "--projects", dir, "--digest", PROD_DIGEST)
      assert_equal 0, rescan_code, rescan
      assert_empty flagged_paths(rescan, dir)

      FLAGGED.each do |rel|
        body = File.read(File.join(dir, rel))
        refute_includes body, PROD, rel
        assert_equal before[rel].lines.reject { |l| l.include?("SECRET_KEY_BASE") },
                     body.lines.reject { |l| l.include?("SECRET_KEY_BASE") },
                     "#{rel}: only the key line changed"
      end
      (LAYOUT.keys - FLAGGED).each do |rel|
        assert_equal before[rel], File.read(File.join(dir, rel)), "#{rel} was not flagged, so not touched"
      end
      keys = FLAGGED.map { |rel| File.read(File.join(dir, rel))[/SECRET_KEY_BASE="?(\h{128})/, 1] }
      assert_equal keys.size, keys.uniq.size, "each file gets its own fresh key"
    end
  end

  # FAIL CLOSED. The heroku stub refuses every read, so there is no production digest
  # to compare against. "Nothing matched" would be vacuously true; exit 4 says so.
  def test_scan_with_no_readable_production_digest_exits_4_not_0
    with_projects do |dir|
      Dir.mktmpdir("stub-bin") do |stub|
        File.write(File.join(stub, "heroku"), "#!/bin/sh\necho 'Invalid credentials' >&2\nexit 1\n")
        File.chmod(0o755, File.join(stub, "heroku"))
        out, err, code = cli("scan", "--projects", dir, "--app", "mcritchie-studio",
                             env: { "PATH" => "#{stub}:#{ENV.fetch("PATH")}" })
        assert_equal 4, code, "#{out}#{err}"
        assert_includes err, "could not read mcritchie-studio"
        assert_empty out, "no table is printed when there is nothing to compare against"
      end
    end
  end

  # The bin/ help-flag class (test/lib/bin_help_flag_class_test.rb): `rewrite --help`
  # must print usage, not write a file named --help; an unknown flag refuses with 2.
  def test_help_and_unknown_flags_write_nothing
    Dir.mktmpdir("dev-secret-key-help") do |dir|
      target = File.join(dir, ".env")
      File.write(target, "SECRET_KEY_BASE=#{PROD}\n")
      Dir.chdir(dir) do
        _out, err, code = cli("rewrite", "--help")
        assert_equal 3, code, "help never answers 0, which a scan uses to mean clean"
        assert_includes err, "usage: bin/dev-secret-key"
        _out, err, code = cli("rewrite", target, "--force")
        assert_equal 2, code
        assert_includes err, "NOTHING ran"
      end
      assert_equal [".env"], Dir.children(dir).sort, "no file named --help was created"
      assert_includes File.read(target), PROD, "a refused rewrite left the file untouched"
    end
  end

  # The production digest read from a (stubbed) Heroku config, end to end: the
  # value passes through the process and only its prefix comes out.
  def test_scan_reads_production_digests_from_heroku_config
    with_projects do |dir|
      Dir.mktmpdir("stub-bin") do |stub|
        File.write(File.join(stub, "heroku"), <<~SH)
          #!/bin/sh
          echo '{"SECRET_KEY_BASE":"#{PROD}","OTHER":"x"}'
        SH
        File.chmod(0o755, File.join(stub, "heroku"))
        out, err, code = cli("scan", "--projects", dir, "--app", "mcritchie-studio",
                             env: { "PATH" => "#{stub}:#{ENV.fetch("PATH")}" })
        assert_equal 1, code, "#{out}#{err}"
        assert_equal FLAGGED.sort, flagged_paths(out, dir)
        assert_includes out, "PRODUCTION (mcritchie-studio)"
        refute_includes out + err, PROD
      end
    end
  end

  # The fresh-machine root cause: ecosystem-build restored a primary's .env straight
  # from the production app's config. Drive restore_env_from_heroku with a heroku stub
  # that answers the way `heroku config --shell` does.
  def test_ecosystem_build_restore_drops_the_production_key_and_writes_a_dev_one
    Dir.mktmpdir("ecosystem-restore") do |tmp|
      stub = File.join(tmp, "bin")
      FileUtils.mkdir_p(stub)
      File.write(File.join(stub, "heroku"), <<~SH)
        #!/bin/sh
        printf '%s\\n' "AWS_REGION=us-east-2" "DATABASE_URL=postgres://prod" "SECRET_KEY_BASE=#{PROD}" "STRIPE_MODE=live"
      SH
      File.chmod(0o755, File.join(stub, "heroku"))
      env_path = File.join(tmp, "app", ".env")
      FileUtils.mkdir_p(File.dirname(env_path))

      script = <<~BASH
        source "#{ECOSYSTEM_BUILD}"
        PATH="#{stub}:#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin"
        restore_env_from_heroku some-prod-app "#{env_path}"
        echo "EXIT=$?"
      BASH
      out, = Open3.capture2e({ "HOME" => tmp, "PROJECTS_DIR" => tmp }, "bash", "-c", script)

      assert_includes out, "EXIT=0", out
      refute_includes out, PROD, "the restore prints no value"
      body = File.read(env_path)
      refute_includes body, PROD, "the production key never lands in a local .env"
      refute_includes body, "DATABASE_URL", "stack-local pointers are still dropped"
      assert_includes body, "AWS_REGION=us-east-2"
      assert_includes body, "STRIPE_MODE=live"
      assert_match(/^SECRET_KEY_BASE=\h{128}$/, body, "a generated development key replaces it")
      assert_equal 0o600, File.stat(env_path).mode & 0o777
    end
  end
end
