# frozen_string_literal: true

# [unit] DevGoogleClient (bin/lib/dev_google_client.rb) — the rewrite that points
# local env files at the dev-only Google client: what it rewrites, what it keeps,
# what it refuses, and that its report never carries a value. Rails-free.
#
#   ruby -Itest test/lib/dev_google_client_test.rb
require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../../bin/lib/dev_google_client"

class DevGoogleClientTest < Minitest::Test
  HUB = "999864627557-9sol5d7l7hnmonhth33d180k068mf0b8.apps.googleusercontent.com"
  DEV_ID = "999864627557-devdevdevdevdevdevdevdevdevdevdev.apps.googleusercontent.com"
  DEV_SECRET = "GOCSPX-dev-secret-never-printed"
  CLI = File.expand_path("../../bin/dev-google-client", __dir__)

  def with_env(body, mode: 0o600)
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      File.write(path, body)
      File.chmod(mode, path)
      yield path, dir
    end
  end

  def test_rewrite_replaces_both_keys_keeps_every_other_line_and_the_mode
    body = "RAILS_ENV=development\nexport GOOGLE_CLIENT_ID=#{HUB}\nGOOGLE_CLIENT_SECRET=\"old-prod-secret\"\n# comment\nOTHER=1"
    with_env(body, mode: 0o640) do |path, _|
      result = DevGoogleClient.apply([path], id: DEV_ID, secret: DEV_SECRET, write: true)

      assert_equal [path], result[:files]
      assert_equal 1, result[:production], "the file sat on the hub's production client before the rewrite"
      assert_equal({ rewritten: 1 }, result[:counts]["GOOGLE_CLIENT_ID"].to_h)
      assert_equal({ rewritten: 1 }, result[:counts]["GOOGLE_CLIENT_SECRET"].to_h)
      assert_equal "RAILS_ENV=development\nexport GOOGLE_CLIENT_ID=#{DEV_ID}\nGOOGLE_CLIENT_SECRET=#{DEV_SECRET}\n# comment\nOTHER=1",
                   File.read(path)
      assert_equal 0o640, File.stat(path).mode & 0o777
    end
  end

  def test_a_file_that_sets_the_id_but_no_secret_gets_one_appended
    with_env("GOOGLE_CLIENT_ID=#{HUB}\nX=1") do |path, _|
      result = DevGoogleClient.apply([path], id: DEV_ID, secret: DEV_SECRET, write: true)
      assert_equal({ appended: 1 }, result[:counts]["GOOGLE_CLIENT_SECRET"].to_h)
      assert_equal "GOOGLE_CLIENT_ID=#{DEV_ID}\nX=1\nGOOGLE_CLIENT_SECRET=#{DEV_SECRET}\n", File.read(path)
    end
  end

  def test_a_template_with_an_empty_id_a_commented_line_or_no_google_line_is_left_alone
    [ "GOOGLE_CLIENT_ID=\nGOOGLE_CLIENT_SECRET=\n", "# GOOGLE_CLIENT_ID=#{HUB}\n", "RAILS_ENV=development\n" ].each do |body|
      with_env(body) do |path, _|
        result = DevGoogleClient.apply([path], id: DEV_ID, secret: DEV_SECRET, write: true)
        assert_empty result[:files], body.inspect
        assert_equal body, File.read(path), "untouched: #{body.inspect}"
      end
    end
  end

  def test_a_dry_run_plans_and_writes_nothing
    body = "GOOGLE_CLIENT_ID=#{HUB}\nGOOGLE_CLIENT_SECRET=old\n"
    with_env(body) do |path, _|
      result = DevGoogleClient.apply([path], id: nil, secret: nil, write: false)
      assert_equal [path], result[:files]
      assert_equal 1, result[:production]
      assert_equal body, File.read(path)
    end
  end

  def test_the_report_carries_paths_and_counts_never_a_value
    with_env("GOOGLE_CLIENT_ID=#{HUB}\nGOOGLE_CLIENT_SECRET=old\n") do |path, _|
      result = DevGoogleClient.apply([path], id: DEV_ID, secret: DEV_SECRET, write: true)
      text = DevGoogleClient.report_lines(result, write: true).join("\n")

      assert_includes text, path
      assert_includes text, "1 file(s) set GOOGLE_CLIENT_ID; 1 of them on a production client"
      assert_includes text, "GOOGLE_CLIENT_SECRET: 1 rewritten, 0 appended, 0 skipped"
      refute_includes text, DEV_SECRET
      refute_includes text, DEV_ID
      refute_includes text, HUB
    end
  end

  def test_the_vault_read_refuses_an_empty_item_and_a_production_client
    empty = ->(_ref) { "" }
    error = assert_raises(DevGoogleClient::Error) { DevGoogleClient.read_from_vault(reader: empty) }
    assert_includes error.message, "no client-id or client-secret yet"

    prod = ->(ref) { ref.end_with?("client-id") ? HUB : "s" }
    error = assert_raises(DevGoogleClient::Error) { DevGoogleClient.read_from_vault(reader: prod) }
    assert_includes error.message, "PRODUCTION client id (mcritchie-studio, tax-studio)"

    dev = ->(ref) { ref.end_with?("client-id") ? " #{DEV_ID}\n" : DEV_SECRET }
    assert_equal({ id: DEV_ID, secret: DEV_SECRET }, DevGoogleClient.read_from_vault(reader: dev))
  end

  def test_the_cli_dry_run_over_a_projects_tree_prints_paths_and_counts_and_reads_no_vault
    Dir.mktmpdir do |projects|
      primary = File.join(projects, "mcritchie-studio")
      desk = File.join(primary, ".worktrees", "demo")
      FileUtils.mkdir_p(desk)
      File.write(File.join(primary, ".env"), "GOOGLE_CLIENT_ID=#{HUB}\nGOOGLE_CLIENT_SECRET=prodsecretmarker\n")
      File.write(File.join(desk, ".env"), "GOOGLE_CLIENT_ID=#{DEV_ID}\nGOOGLE_CLIENT_SECRET=desksecretmarker\n")
      File.write(File.join(projects, ".env.example"), "GOOGLE_CLIENT_ID=\n")

      out, err, status = Open3.capture3({ "PATH" => "/nonexistent" }, RbConfig.ruby, CLI, "--projects", projects)

      assert status.success?, err
      assert_includes out, "2 file(s) set GOOGLE_CLIENT_ID; 1 of them on a production client"
      assert_includes out, "dry run: nothing written"
      refute_includes out, "secretmarker", "no value, from any file, reaches the report"
      refute_includes out, HUB
      assert_equal "GOOGLE_CLIENT_ID=#{HUB}\nGOOGLE_CLIENT_SECRET=prodsecretmarker\n", File.read(File.join(primary, ".env"))
    end
  end
end
