# frozen_string_literal: true

# [unit] bin/lib/dev_secret_key.rb: a local env file's SECRET_KEY_BASE is a freshly
# generated development key, and a scan names every file still holding a
# production one. Pure Ruby, no Rails:
#   ruby -Itest test/lib/dev_secret_key_test.rb
#
# The fixture "production" key below is a made-up constant. The point of every
# assertion is that a value which went IN never comes back OUT: not in the
# rewritten file, not in a scan row.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/dev_secret_key"

class DevSecretKeyTest < Minitest::Test
  PROD = "f" * 128 # stands in for a production key; never a real one
  PROD_DIGEST = Digest::SHA256.hexdigest(PROD)

  def within_tmp
    Dir.mktmpdir("dev-secret-key") { |dir| yield dir }
  end

  # --- generate ---------------------------------------------------------------

  def test_generate_is_a_128_hex_key_and_never_repeats
    a = DevSecretKey.generate
    b = DevSecretKey.generate
    assert_match(/\A\h{128}\z/, a, "the shape `bin/rails secret` prints")
    refute_equal a, b
  end

  # --- read_value / parse_value ----------------------------------------------

  def test_read_value_reads_plain_export_quoted_and_commented_forms
    within_tmp do |dir|
      {
        "SECRET_KEY_BASE=abc\n" => "abc",
        "export SECRET_KEY_BASE=abc\n" => "abc",
        "SECRET_KEY_BASE=\"abc\"\n" => "abc",
        "SECRET_KEY_BASE='abc'\n" => "abc",
        "SECRET_KEY_BASE=abc   # note\n" => "abc",
        "SECRET_KEY_BASE=                  # template\n" => ""
      }.each do |content, want|
        path = File.join(dir, ".env")
        File.write(path, "A=1\n#{content}")
        assert_equal want, DevSecretKey.read_value(path), content.inspect
      end
    end
  end

  def test_read_value_is_nil_without_a_line_or_a_file
    within_tmp do |dir|
      path = File.join(dir, ".env")
      assert_nil DevSecretKey.read_value(path), "no file"
      File.write(path, "SECRET_KEY_BASE_DUMMY=1\n# SECRET_KEY_BASE=old\n")
      assert_nil DevSecretKey.read_value(path), "a longer name and a comment are not the key"
    end
  end

  # --- rewrite -----------------------------------------------------------------

  def test_rewrite_replaces_the_value_keeps_every_other_line_and_the_mode
    within_tmp do |dir|
      path = File.join(dir, ".env")
      File.write(path, "A=1\nSECRET_KEY_BASE=#{PROD}\nB=2\n")
      File.chmod(0o640, path)

      digest = DevSecretKey.rewrite(path)

      body = File.read(path)
      refute_includes body, PROD, "the production value is gone"
      assert_equal %w[A=1 B=2], body.lines.map(&:chomp).reject { |l| l.start_with?("SECRET_KEY_BASE=") }
      value = DevSecretKey.read_value(path)
      assert_match(/\A\h{128}\z/, value)
      assert_equal Digest::SHA256.hexdigest(value), digest, "returns the NEW value's digest"
      refute_equal PROD_DIGEST, digest
      assert_equal 0o640, File.stat(path).mode & 0o777, "permissions survive the atomic write"
    end
  end

  def test_rewrite_sets_every_duplicate_line_to_the_one_new_value
    within_tmp do |dir|
      path = File.join(dir, ".env")
      File.write(path, "SECRET_KEY_BASE=#{PROD}\nexport SECRET_KEY_BASE=#{PROD}\n")
      DevSecretKey.rewrite(path)
      values = File.readlines(path).map { |l| l[/=(.*)/, 1] }
      assert_equal 1, values.uniq.size, "a duplicate line cannot keep the old key alive"
      refute_includes File.read(path), PROD
      assert File.read(path).lines.last.start_with?("export "), "an export prefix is kept"
    end
  end

  def test_rewrite_appends_when_no_line_sets_the_key_and_creates_0600
    within_tmp do |dir|
      path = File.join(dir, ".env")
      File.write(path, "A=1") # no trailing newline
      DevSecretKey.rewrite(path)
      assert_equal "A=1", File.readlines(path).first.chomp
      assert_match(/\ASECRET_KEY_BASE=\h{128}\n\z/, File.readlines(path).last)

      fresh = File.join(dir, "new", ".env")
      DevSecretKey.rewrite(fresh)
      assert_equal 0o600, File.stat(fresh).mode & 0o777, "a new env file is owner-only"
      assert_empty Dir.glob(File.join(dir, "**", "*.tmp"), File::FNM_DOTMATCH), "no temp file is left behind"
    end
  end

  # --- replace_in_copy (the desk provisioning hook) ---------------------------

  def test_replace_in_copy_swaps_a_set_key_and_leaves_empty_or_absent_alone
    within_tmp do |dir|
      set = File.join(dir, "set.env")
      File.write(set, "SECRET_KEY_BASE=#{PROD}\n")
      refute_nil DevSecretKey.replace_in_copy(set)
      refute_includes File.read(set), PROD

      empty = File.join(dir, "empty.env")
      File.write(empty, "SECRET_KEY_BASE=\n")
      assert_nil DevSecretKey.replace_in_copy(empty)
      assert_equal "SECRET_KEY_BASE=\n", File.read(empty), "an empty template stays a template"

      absent = File.join(dir, "absent.env")
      File.write(absent, "A=1\n")
      assert_nil DevSecretKey.replace_in_copy(absent)
      assert_equal "A=1\n", File.read(absent), "no key is invented for a file that set none"
    end
  end

  # --- scan ----------------------------------------------------------------------

  def test_scan_classifies_production_dev_empty_and_absent_by_digest_only
    within_tmp do |dir|
      files = {
        "prod" => "SECRET_KEY_BASE=#{PROD}\n",
        "dev" => "SECRET_KEY_BASE=#{"a" * 128}\n",
        "empty" => "SECRET_KEY_BASE=\n",
        "absent" => "A=1\n"
      }.to_h do |name, body|
        path = File.join(dir, name)
        File.write(path, body)
        [name, path]
      end

      rows = DevSecretKey.scan(files.values, { PROD_DIGEST => "mcritchie-studio" }).to_h { |r| [File.basename(r[:path]), r] }

      assert_equal :production, rows["prod"][:state]
      assert_equal "mcritchie-studio", rows["prod"][:app]
      assert_equal PROD_DIGEST[0, 8], rows["prod"][:prefix]
      assert_equal :dev, rows["dev"][:state]
      assert_equal :empty, rows["empty"][:state]
      assert_equal :absent, rows["absent"][:state]
      rows.each_value do |row|
        refute(row.values.any? { |v| v.to_s.include?(PROD) }, "a scan row never carries a value")
      end
    end
  end

  def test_default_files_finds_the_root_primaries_and_desks_including_dotfiles
    within_tmp do |dir|
      paths = [
        ".env", # the shared projects-root file
        "mcritchie-studio/.env", "turf-monster/.env",
        "mcritchie-studio/.worktrees/some-desk/.env",
        "mcritchie-studio/.worktrees/some-desk/.env.development"
      ].map { |rel| File.join(dir, rel) }
      paths.each { |p| FileUtils.mkdir_p(File.dirname(p)) && File.write(p, "A=1\n") }
      FileUtils.mkdir_p(File.join(dir, "mcritchie-studio/app"))
      File.write(File.join(dir, "mcritchie-studio/app/.env"), "deeper than a primary root\n")

      assert_equal paths.sort, DevSecretKey.default_files(dir)
    end
  end

  # --- heroku_digests --------------------------------------------------------------

  def test_heroku_digests_hashes_each_value_and_lists_unreadable_apps
    configs = {
      "hub" => [%({"SECRET_KEY_BASE":"#{PROD}","A":"1"}), true],
      "no-key" => ['{"A":"1"}', true],
      "denied" => ["", false],
      "garbage" => ["not json", true],
      "empty" => ["{}", true]
    }
    digests, unread = DevSecretKey.heroku_digests(configs.keys, runner: ->(app) { configs.fetch(app) })

    assert_equal({ PROD_DIGEST => "hub" }, digests)
    assert_equal %w[denied garbage empty], unread,
                 "a failed, unparseable or empty read is UNREAD, never a clean answer"
  end

  # --- the production-only deny list (local-envs-drop-mainnet-keys) ---------------

  ADMIN = "5" * 88 # stands in for a base58 Solana secret; never a real one

  def test_deny_list_leads_with_the_mainnet_signer_and_spares_the_by_design_keys
    assert_equal "SOLANA_ADMIN_KEY", DevSecretKey::PRODUCTION_ONLY_KEYS.first,
                 "the key that signs money heads the list"
    %w[CDP_API_KEY_ID CDP_API_KEY_SECRET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
       RESEND_API_KEY GITHUB_TOKEN].each do |key|
      assert DevSecretKey.production_only?(key), key
    end
    # CONTROL: the keys local dev needs by design are NOT denied, so the filter
    # below is not passing by dropping everything.
    %w[RAILS_MASTER_KEY AGENT_API_SECRET SECRET_KEY_BASE SOLANA_RPC_URL].each do |key|
      refute DevSecretKey.production_only?(key), key
    end
  end

  def test_filter_drops_every_denied_line_and_keeps_the_rest_verbatim
    dump = <<~ENV
      AWS_REGION=us-east-2
      SOLANA_ADMIN_KEY=#{ADMIN}
      export CDP_API_KEY_ID='organizations/x/apiKeys/y'
      RAILS_MASTER_KEY=#{PROD}
      AWS_ACCESS_KEY_ID=AKIAEXAMPLE
      AWS_SECRET_ACCESS_KEY="abc/def"
      RESEND_API_KEY=re_example
      GITHUB_TOKEN=ghp_example
      AGENT_API_SECRET=keepme
      SOLANA_ADMIN_KEY_PUBLIC=not-the-key
    ENV

    kept, dropped = DevSecretKey.filter_production_only(dump)

    assert_equal %w[SOLANA_ADMIN_KEY CDP_API_KEY_ID AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
                    RESEND_API_KEY GITHUB_TOKEN], dropped
    assert_equal <<~ENV, kept
      AWS_REGION=us-east-2
      RAILS_MASTER_KEY=#{PROD}
      AGENT_API_SECRET=keepme
      SOLANA_ADMIN_KEY_PUBLIC=not-the-key
    ENV
    refute_includes dropped.join, ADMIN, "the names come back, never a value"
  end

  # A quoted multi-line value (a PEM, the way `heroku config --shell` prints one)
  # is dropped whole: no tail line survives as a stray.
  def test_filter_drops_a_multi_line_value_whole
    dump = "A=1\nCDP_API_KEY_SECRET='-----BEGIN KEY-----\nline-two\n-----END KEY-----'\nB=2\n"
    kept, dropped = DevSecretKey.filter_production_only(dump)
    assert_equal "A=1\nB=2\n", kept
    assert_equal %w[CDP_API_KEY_SECRET], dropped
  end

  def test_read_value_and_scan_take_any_key
    within_tmp do |dir|
      path = File.join(dir, ".env")
      File.write(path, "SECRET_KEY_BASE=#{PROD}\nSOLANA_ADMIN_KEY=\"#{ADMIN}\"\nGITHUB_TOKEN=\n")
      assert_equal ADMIN, DevSecretKey.read_value(path, "SOLANA_ADMIN_KEY")
      assert_equal PROD, DevSecretKey.read_value(path), "the default key is still SECRET_KEY_BASE"

      by_key = { "SOLANA_ADMIN_KEY" => { Digest::SHA256.hexdigest(ADMIN) => "turf-monster-mainnet" } }
      rows = DevSecretKey.scan_production_only([path], by_key)
      admin = rows.find { |r| r[:key] == "SOLANA_ADMIN_KEY" }
      assert_equal :production, admin[:state]
      assert_equal "turf-monster-mainnet", admin[:app]
      assert_equal :empty, rows.find { |r| r[:key] == "GITHUB_TOKEN" }[:state]
      refute(rows.any? { |r| r[:key] == "AWS_ACCESS_KEY_ID" }, "a key the file never sets is not a row")
      refute_includes rows.inspect, ADMIN
    end
  end

  def test_remove_key_drops_only_that_key_and_keeps_permissions
    within_tmp do |dir|
      path = File.join(dir, ".env")
      File.write(path, "A=1\nSOLANA_ADMIN_KEY=#{ADMIN}\nexport SOLANA_ADMIN_KEY=#{ADMIN}\nB=2\n")
      File.chmod(0o600, path)
      assert_equal 2, DevSecretKey.remove_key(path, "SOLANA_ADMIN_KEY")
      assert_equal "A=1\nB=2\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 0, DevSecretKey.remove_key(path, "SOLANA_ADMIN_KEY"), "idempotent"
    end
  end

  def test_heroku_digests_by_key_reads_each_app_once_for_every_key
    calls = Hash.new(0)
    configs = {
      "turf" => [%({"SOLANA_ADMIN_KEY":"#{ADMIN}","SECRET_KEY_BASE":"#{PROD}"}), true],
      "denied" => ["", false]
    }
    runner = lambda do |app|
      calls[app] += 1
      configs.fetch(app)
    end
    by_key, unread = DevSecretKey.heroku_digests_by_key(configs.keys, runner: runner)
    assert_equal({ Digest::SHA256.hexdigest(ADMIN) => "turf" }, by_key.fetch("SOLANA_ADMIN_KEY"))
    assert_equal({ PROD_DIGEST => "turf" }, by_key.fetch("SECRET_KEY_BASE"))
    assert_equal({}, by_key.fetch("GITHUB_TOKEN"))
    assert_equal %w[denied], unread
    assert_equal({ "turf" => 1, "denied" => 1 }, calls, "one config read per app, not one per key")
  end

  # Carl's bounce (2026-10-07): a turf restore also carried the mainnet
  # managed-wallet key and live Stripe.
  def test_deny_list_covers_the_mainnet_wallet_key_and_live_stripe
    %w[MANAGED_WALLET_ENCRYPTION_KEY MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS
       STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET].each do |key|
      assert DevSecretKey.production_only?(key), key
    end
    kept, dropped = DevSecretKey.filter_production_only(
      "MANAGED_WALLET_ENCRYPTION_KEY=w\nSTRIPE_SECRET_KEY=sk_live_x\nSTRIPE_PUBLISHABLE_KEY=pk\n"
    )
    assert_equal "STRIPE_PUBLISHABLE_KEY=pk\n", kept, "control: a non-secret sibling is kept"
    assert_equal %w[MANAGED_WALLET_ENCRYPTION_KEY STRIPE_SECRET_KEY], dropped
  end

  # QA values are left alone: local turf shares QA's wallet key on purpose. A QA
  # app's SECRET_KEY_BASE is still recorded (control), its production-only values not.
  def test_production_only_digests_come_from_production_apps_only
    configs = {
      "turf-monster-mainnet" => [%({"MANAGED_WALLET_ENCRYPTION_KEY":"mainnet-w"}), true],
      "turf-monster-qa" => [%({"MANAGED_WALLET_ENCRYPTION_KEY":"qa-w","SECRET_KEY_BASE":"#{PROD}"}), true]
    }
    by_key, = DevSecretKey.heroku_digests_by_key(configs.keys, runner: ->(app) { configs.fetch(app) })
    assert_equal({ Digest::SHA256.hexdigest("mainnet-w") => "turf-monster-mainnet" },
                 by_key.fetch("MANAGED_WALLET_ENCRYPTION_KEY"))
    assert_equal({ PROD_DIGEST => "turf-monster-qa" }, by_key.fetch("SECRET_KEY_BASE"))
  end

  def test_strip_production_only_rewrites_only_when_something_is_denied
    within_tmp do |dir|
      path = File.join(dir, ".env")
      File.write(path, "A=1\nSTRIPE_WEBHOOK_SECRET=whsec\n")
      assert_equal %w[STRIPE_WEBHOOK_SECRET], DevSecretKey.strip_production_only(path)
      assert_equal "A=1\n", File.read(path)
      assert_empty DevSecretKey.strip_production_only(path)
      assert_empty DevSecretKey.strip_production_only(File.join(dir, "missing"))
    end
  end
end
