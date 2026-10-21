require "test_helper"
require "open3"
require "tmpdir"

# [unit] bin/client-bundle: the CLI refuses a bad directory before it sends
# anything, and needs an agent session to publish (it holds no storage key).
class ClientBundleCliTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/client-bundle").to_s

  def run_cli(*args, env: {})
    Open3.capture3({ "CLIENT_BUNDLE_SESSION_TOKEN" => nil, "AGENT_ADMIN_SESSION_TOKEN" => nil }.merge(env), "ruby", BIN, *args)
  end

  test "[unit] check passes the demo bundle" do
    out, _err, status = run_cli("check", Rails.root.join("test/fixtures/files/client_bundles/demo").to_s)
    assert status.success?
    assert_match(/\Aok: 5 files/, out)
  end

  test "[unit] check and publish refuse a symlink and server code, sending nothing" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "index.html"), "<!doctype html><main data-studio-content></main>")
      File.write(File.join(dir, "server.rb"), "puts 1")
      File.symlink("/etc/hosts", File.join(dir, "hosts.txt"))

      _out, err, status = run_cli("check", dir)
      assert_not status.success?
      assert_includes err, "hosts.txt is a symlink"

      File.delete(File.join(dir, "hosts.txt"))
      _out, err, status = run_cli("publish", "pawsome", dir, "--api", "http://127.0.0.1:9")
      assert_not status.success?
      assert_includes err, "nothing was sent"
      assert_includes err, "server.rb is not a static file type"
    end
  end

  test "[unit] usage errors" do
    _out, _err, status = run_cli("publish", "only-one-arg")
    assert_not status.success?
    _out, err, status = run_cli("publish", "a", "b", "--local", "--api", "http://x")
    assert_not status.success?
    assert_includes err, "separate runs"
  end
end
