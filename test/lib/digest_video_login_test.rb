# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "socket"
require "tmpdir"
require_relative "../../bin/lib/digest_video"

# [integration] The real ApiClient against a local HTTP stub: a failed login
# stops the run before R2 is touched, and a bad auth body is never echoed.
class DigestVideoLoginTest < Minitest::Test
  URL = "https://www.youtube.com/watch?v=Sa7GSJJ_lOo"

  class UntouchedStorage
    attr_reader :calls

    def initialize = @calls = []

    def put(*args) = @calls << args
  end

  def probe = ->(*_cmd) { [JSON.generate("streams" => [{ "codec_type" => "video", "codec_name" => "h264" },
                                                       { "codec_type" => "audio", "codec_name" => "aac" }],
                                         "format" => { "duration" => "1.0" }), "", true] }

  # Answers every request with one canned response; records the paths hit.
  def with_server(status, body)
    server = TCPServer.new("127.0.0.1", 0)
    paths = []
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets.to_s
        paths << request_line.split[1]
        length = 0
        while (line = client.gets) && line != "\r\n"
          length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length")
        end
        client.read(length)
        client.write("HTTP/1.1 #{status}\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\n" \
                     "Connection: close\r\n\r\n#{body}")
        client.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}", paths
  ensure
    thread&.kill
    server&.close
  end

  def run_against(base)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Sa7GSJJ_lOo.mp4"), "video")
      File.write(File.join(dir, "Sa7GSJJ_lOo.info.json"), JSON.generate("id" => "Sa7GSJJ_lOo", "title" => "A - B"))
      storage = UntouchedStorage.new
      api = DigestVideo::ApiClient.new(base_url: base, repo_root: dir)
      error = assert_raises(DigestVideo::Failure) do
        DigestVideo::Runner.new(workdir: dir, shell: probe, storage: storage, api: api, out: StringIO.new,
                                from_dir: dir).call(URL)
      end
      yield error, storage
    end
  end

  def setup = ENV["AGENT_API_SECRET"] = "test-secret"

  def teardown = ENV.delete("AGENT_API_SECRET")

  def test_failed_login_uploads_nothing
    with_server("401 Unauthorized", '{"error":"bad secret"}') do |base, paths|
      run_against(base) do |error, storage|
        assert_match(/API auth 401/, error.message)
        assert_empty storage.calls
        assert_equal ["/api/v1/auth"], paths
      end
    end
  end

  def test_unparseable_auth_body_fails_without_echoing_it
    with_server("200 OK", "<html>SECRETBODY proxy page</html>") do |base, _paths|
      run_against(base) do |error, storage|
        assert_match(/not JSON/, error.message)
        refute_includes error.message, "SECRETBODY"
        assert_empty storage.calls
      end
    end
  end
end
