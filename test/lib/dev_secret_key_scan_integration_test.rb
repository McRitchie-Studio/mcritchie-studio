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
  # --- production-only keys (local-envs-drop-mainnet-keys) -------------------------
  #
  # The 2026-10-06 shape: the turf primary and its desks held turf-monster-mainnet's
  # SOLANA_ADMIN_KEY, and the hub held production AWS, Resend and GitHub tokens, all
  # copied out of `heroku config` by the old restore.
  ADMIN = "5" * 88 # stands in for a base58 Solana secret; never a real one
  AWS = "aws-secret-" + ("9" * 30)
  MASTER = "e" * 32
  LOCAL_AWS = "a-local-only-aws-key-#{"1" * 20}"
  QA_WALLET = "qa-wallet-key-#{"7" * 30}"

  ONLY_LAYOUT = {
    "turf-monster/.env" => "SOLANA_ADMIN_KEY=#{ADMIN}\nRAILS_MASTER_KEY=#{MASTER}\n",
    "turf-monster/.worktrees/desk-three/.env" => "export SOLANA_ADMIN_KEY=\"#{ADMIN}\"\nA=1\n",
    "turf-monster/.worktrees/_ship/.env" => "SOLANA_ADMIN_KEY=#{ADMIN}\n",
    "mcritchie-studio/.env" => "AWS_SECRET_ACCESS_KEY=#{AWS}\nB=2\n",
    # CONTROLS: a deny-listed key on a NON-production value, and a by-design key on
    # a production value. Neither is a production-only match, so neither is touched.
    "mcritchie-studio/.worktrees/desk-one/.env" => "AWS_SECRET_ACCESS_KEY=#{LOCAL_AWS}\n",
    "rolio/.env" => "RAILS_MASTER_KEY=#{MASTER}\n",
    # CONTROL: QA's managed-wallet key, which local turf shares on purpose. A QA
    # app's production-only value is not a production match, so it stays.
    "turf-monster/.worktrees/desk-four/.env" => "MANAGED_WALLET_ENCRYPTION_KEY=#{QA_WALLET}\n"
  }.freeze

  ONLY_FLAGGED = %w[
    mcritchie-studio/.env
    turf-monster/.env
    turf-monster/.worktrees/_ship/.env
    turf-monster/.worktrees/desk-three/.env
  ].freeze

  def with_only_projects
    Dir.mktmpdir("dev-secret-key-only") do |dir|
      ONLY_LAYOUT.each do |rel, body|
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      yield dir
    end
  end

  # A heroku stub answering `config --json` the way turf-monster-mainnet and the hub
  # would: the production-only values plus a by-design RAILS_MASTER_KEY.
  def with_prod_heroku
    Dir.mktmpdir("stub-bin") do |stub|
      File.write(File.join(stub, "heroku"), <<~SH)
        #!/bin/sh
        case "$*" in
          *turf-monster-qa*) echo '{"MANAGED_WALLET_ENCRYPTION_KEY":"#{QA_WALLET}","SOLANA_ADMIN_KEY":"#{ADMIN}"}' ;;
          *) echo '{"SOLANA_ADMIN_KEY":"#{ADMIN}","AWS_SECRET_ACCESS_KEY":"#{AWS}","RAILS_MASTER_KEY":"#{MASTER}"}' ;;
        esac
      SH
      File.chmod(0o755, File.join(stub, "heroku"))
      yield({ "PATH" => "#{stub}:#{ENV.fetch("PATH")}" })
    end
  end

  def test_scan_flags_production_only_keys_by_digest_and_fix_leaves_zero_matches
    with_only_projects do |dir|
      with_prod_heroku do |env|
        before = ONLY_LAYOUT.keys.to_h { |rel| [rel, File.read(File.join(dir, rel))] }

        out, err, code = cli("scan", "--projects", dir, "--app", "turf-monster-mainnet", "--app", "turf-monster-qa", env: env)
        assert_equal 1, code, "a production-only value on disk is a failing scan\n#{out}#{err}"
        assert_equal ONLY_FLAGGED, flagged_paths(out, dir)
        assert_match(%r{turf-monster/\.env\s+SOLANA_ADMIN_KEY\s+\h{8}\s+PRODUCTION \(turf-monster-mainnet\)}, out)
        assert_match(%r{desk-one/\.env\s+AWS_SECRET_ACCESS_KEY\s+\h{8}\s+dev}, out,
                     "control: a deny-listed key on a local value is reported, not flagged")
        assert_match(%r{desk-four/\.env\s+MANAGED_WALLET_ENCRYPTION_KEY\s+\h{8}\s+dev}, out,
                     "control: a QA app's wallet key is not a production match")
        assert_match(/production-only keys: 6 set, 4 hold a production value \(SOLANA_ADMIN_KEY,/, out)
        [ADMIN, AWS, MASTER, LOCAL_AWS].each { |v| refute_includes out + err, v, "no value is ever printed" }

        out, err, code = cli("fix", "--projects", dir, "--app", "turf-monster-mainnet", "--app", "turf-monster-qa", env: env)
        assert_equal 0, code, "#{out}#{err}"
        assert_match(/production-only keys: 4 production value\(s\), 4 removed, 0 still production/, out)

        rescan, rescan_err, rescan_code = cli("scan", "--projects", dir, "--app", "turf-monster-mainnet", "--app", "turf-monster-qa", env: env)
        assert_equal 0, rescan_code, "#{rescan}#{rescan_err}"
        assert_empty flagged_paths(rescan, dir), "zero production matches after the fix"
        assert_match(/production-only keys: 2 set, 0 hold a production value/, rescan)

        ONLY_FLAGGED.each do |rel|
          body = File.read(File.join(dir, rel))
          [ADMIN, AWS].each { |v| refute_includes body, v, rel }
        end
        assert_includes File.read(File.join(dir, "turf-monster/.env")), "RAILS_MASTER_KEY=#{MASTER}",
                        "a by-design key survives the fix beside a removed one"
        assert_equal "A=1\n", File.read(File.join(dir, "turf-monster/.worktrees/desk-three/.env"))
        %w[mcritchie-studio/.worktrees/desk-one/.env rolio/.env turf-monster/.worktrees/desk-four/.env].each do |rel|
          assert_equal before[rel], File.read(File.join(dir, rel)), "control #{rel} was not touched"
        end
      end
    end
  end

  # The fresh-machine leak itself: restore_env_from_heroku against a stub that
  # answers `heroku config --shell` with every production-only key.
  def test_ecosystem_build_restore_drops_every_production_only_key
    Dir.mktmpdir("ecosystem-restore-only") do |tmp|
      stub = File.join(tmp, "bin")
      FileUtils.mkdir_p(stub)
      File.write(File.join(stub, "heroku"), <<~SH)
        #!/bin/sh
        printf '%s\\n' "SOLANA_ADMIN_KEY=#{ADMIN}" "AWS_ACCESS_KEY_ID=AKIAEXAMPLE" "AWS_SECRET_ACCESS_KEY=#{AWS}" \\
          "RESEND_API_KEY=re_x" "GITHUB_TOKEN=ghp_x" "CDP_API_KEY_ID=cdp_x" "CDP_API_KEY_SECRET=cdp_s" \\
          "MANAGED_WALLET_ENCRYPTION_KEY=mw_x" "STRIPE_SECRET_KEY=sk_live_x" "STRIPE_WEBHOOK_SECRET=whsec_x" \\
          "RAILS_MASTER_KEY=#{MASTER}" "AGENT_API_SECRET=agent_x" "SOLANA_NETWORK=devnet"
      SH
      File.chmod(0o755, File.join(stub, "heroku"))
      env_path = File.join(tmp, "app", ".env")
      FileUtils.mkdir_p(File.dirname(env_path))

      script = <<~BASH
        source "#{ECOSYSTEM_BUILD}"
        PATH="#{stub}:#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin"
        restore_env_from_heroku turf-monster-mainnet "#{env_path}"
        echo "EXIT=$?"
      BASH
      out, = Open3.capture2e({ "HOME" => tmp, "PROJECTS_DIR" => tmp }, "bash", "-c", script)

      assert_includes out, "EXIT=0", out
      [ADMIN, AWS].each { |v| refute_includes out, v, "the restore prints no value" }
      body = File.read(env_path)
      DevSecretKeyScanIntegrationTest.deny_list.each do |key|
        refute_match(/^#{key}=/, body, "#{key} never lands in a restored .env")
      end
      assert_includes body, "RAILS_MASTER_KEY=#{MASTER}", "by design: the master key is restored"
      assert_includes body, "AGENT_API_SECRET=agent_x", "by design: the agent secret is restored"
      assert_includes body, "SOLANA_NETWORK=devnet"
      assert_equal 0o600, File.stat(env_path).mode & 0o777
    end
  end

  # FAIL CLOSED: no ruby means no filter, and an unfiltered restore is the leak.
  def test_ecosystem_build_restore_without_the_filter_writes_nothing
    Dir.mktmpdir("ecosystem-restore-noruby") do |tmp|
      stub = File.join(tmp, "bin")
      FileUtils.mkdir_p(stub)
      File.write(File.join(stub, "heroku"), "#!/bin/sh\nprintf '%s\\n' 'SOLANA_ADMIN_KEY=#{ADMIN}'\n")
      File.chmod(0o755, File.join(stub, "heroku"))
      # PATH is ONLY this stub dir: the tools the function calls, and no ruby. macOS
      # ships /usr/bin/ruby, so leaving /usr/bin on PATH could never stage the case.
      %w[dirname basename grep rm chmod cat].each do |tool|
        found = ["/usr/bin/#{tool}", "/bin/#{tool}"].find { |p| File.executable?(p) }
        File.symlink(found, File.join(stub, tool)) if found
      end
      env_path = File.join(tmp, "app", ".env")
      FileUtils.mkdir_p(File.dirname(env_path))

      script = <<~BASH
        source "#{ECOSYSTEM_BUILD}"
        PATH="#{stub}"
        command -v ruby >/dev/null 2>&1 && echo "RUBY_VISIBLE"
        restore_env_from_heroku turf-monster-mainnet "#{env_path}"
        echo "EXIT=$?"
      BASH
      out, = Open3.capture2e({ "HOME" => tmp, "PROJECTS_DIR" => tmp }, "bash", "-c", script)

      refute_includes out, "RUBY_VISIBLE", "the staged PATH must hide ruby"
      assert_includes out, "EXIT=1", out
      assert_includes out, "not restored", "the operator is told why"
      refute File.exist?(env_path), "no .env is written without the filter"
      refute_includes out, ADMIN
    end
  end

  def self.deny_list
    require_relative "../../bin/lib/dev_secret_key"
    DevSecretKey::PRODUCTION_ONLY_KEYS
  end
end
