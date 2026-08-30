require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "fileutils"
require "json"

# [integration] The session lifecycle END TO END: real git, both real binaries,
# a real cache file on disk.
#
# WHY THIS TIER EXISTS AND THE UNIT TESTS ARE NOT ENOUGH. The unit tests stub one
# side each — the helper's tests stub bin/gh-token, and bin/gh-token's tests call
# it directly. Neither can catch the thing most likely to break: the CONTRACT
# BETWEEN THEM. The helper shells out to `gh-token --reject "$password"`, and if
# that flag were renamed, reordered, or made to expect stdin, every unit test on
# both sides would still pass while a revoked token was served forever.
#
# So this drives GIT ITSELF against a server that answers 401, and asserts on the
# cache file both binaries share. Nothing here is stubbed except the remote.
#
# THE PROTOCOL FACT THIS RESTS ON, measured 2026-08-30 rather than assumed: git
# calls a credential helper with `get`, and when the credential it returned is
# REJECTED it calls the SAME helper again with `erase`, handing the failed
# password back on stdin. That second call is the only notice a helper ever
# receives that a token has gone bad — it never sees the 401.
class CredentialSessionLifecycleTest < ActiveSupport::TestCase
  HELPER = Rails.root.join("bin/gh-app-git-credential").to_s
  GH_TOKEN = Rails.root.join("bin/gh-token").to_s

  test "a warm session is served to git and a rejected one is retired from the shared cache" do
    Dir.mktmpdir do |dir|
      seed_cache(dir, "ghs_LIVESESSION")

      with_401_server do |url|
        _out, _err, _status = Open3.capture3(env(dir), "git", "ls-remote", url, "HEAD")
      end

      # THE CACHE IS THE ASSERTION, not the command's exit status. git ALWAYS
      # fails against a 401; what matters is that the round trip removed the
      # token, so the next request mints instead of re-serving a dead credential.
      assert_nil slot(dir, "a"),
                 "git rejected this session, so the erase must have retired it from the " \
                 "cache both binaries share — otherwise every later git operation " \
                 "re-serves a token GitHub has already refused"
    end
  end

  # THE PROPERTY THE MATCH BUYS. The cache is shared across sibling agent
  # processes; between one agent's `get` and git's `erase`, another may already
  # have minted a replacement into the other slot. A blind purge would discard
  # that fresh session and send every sibling back to 1Password — the cost this
  # cache exists to avoid.
  test "a rejection leaves a sibling's newer session in place" do
    Dir.mktmpdir do |dir|
      seed_cache(dir, "ghs_LIVESESSION", sibling: "ghs_SIBLINGFRESH")

      with_401_server do |url|
        Open3.capture3(env(dir), "git", "ls-remote", url, "HEAD")
      end

      assert_nil slot(dir, "a"), "the rejected slot is retired"
      assert_equal "ghs_SIBLINGFRESH", slot(dir, "b"),
                   "a sibling's session must survive another agent's rejection"
    end
  end

  private

  # A server that answers every request 401 with a Basic challenge, so git asks
  # the helper, fails, and then erases. Bound on loopback, port 0 (kernel-chosen)
  # so concurrent test runs never collide.
  def with_401_server
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      while (client = server.accept)
        client.gets
        while (line = client.gets) && line.strip != ""; end
        client.write("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"git\"\r\n" \
                     "Content-Length: 0\r\n\r\n")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}/probe/repo.git"
  ensure
    server&.close
    thread&.kill
  end

  # `created_at` is stamped NOW so the token is inside the freshness window. A
  # stale slot would be skipped for a different reason and the test would pass
  # without exercising the rejection at all.
  def seed_cache(dir, token, sibling: nil)
    entry = { "a" => { "token" => token, "created_at" => Time.now.utc.iso8601 }, "active" => "a" }
    entry["b"] = { "token" => sibling, "created_at" => Time.now.utc.iso8601 } if sibling
    FileUtils.mkdir_p(File.join(dir, ".agents"))
    File.write(cache_path(dir), JSON.generate("agent" => entry))
  end

  def cache_path(dir) = File.join(dir, ".agents", "github-tokens.json")

  def slot(dir, key)
    JSON.parse(File.read(cache_path(dir))).dig("agent", key, "token")
  rescue StandardError
    nil
  end

  def env(dir)
    { "CLAUDE_PROJECTS_DIR" => dir,
      "GH_APP_TOKEN_CMD" => GH_TOKEN,
      "GIT_TERMINAL_PROMPT" => "0",
      # Replace the ambient helper list entirely: a `-c credential.helper=X`
      # APPENDS, so the machine's real helper would answer first and this test
      # would silently exercise nothing. Measured — it cost three probe attempts.
      "GIT_CONFIG_COUNT" => "2",
      "GIT_CONFIG_KEY_0" => "credential.helper",
      "GIT_CONFIG_VALUE_0" => "",
      "GIT_CONFIG_KEY_1" => "credential.helper",
      "GIT_CONFIG_VALUE_1" => HELPER }
  end
end
