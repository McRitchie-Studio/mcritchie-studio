# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/digest_video"

# [unit] Credits that cannot name an R2 folder (no key-safe characters) stop
# with a named Failure before any upload, never an ArgumentError stack trace.
class DigestVideoCreditKeysTest < Minitest::Test
  ID = "Zz9_yy-XX8w"
  URL = "https://www.youtube.com/watch?v=#{ID}"

  Shell = Struct.new(:info) do
    def call(*cmd)
      if File.basename(cmd.first) == "yt-dlp"
        dir = cmd[cmd.index("-P") + 1]
        File.write(File.join(dir, "#{ID}.mp4"), "video")
        File.write(File.join(dir, "#{ID}.info.json"), JSON.generate(info))
        return ["", "", true]
      end
      [JSON.generate("streams" => [{ "codec_type" => "video", "codec_name" => "h264" },
                                   { "codec_type" => "audio", "codec_name" => "aac" }],
                     "format" => { "duration" => "60.0" }), "", true]
    end
  end

  class Untouchable
    def method_missing(name, *) = raise("#{name} must not run before the key exists")

    def respond_to_missing?(*) = true
  end

  def digest(info)
    Dir.mktmpdir do |dir|
      DigestVideo::Runner.new(workdir: dir, shell: Shell.new(info), storage: Untouchable.new, api: Untouchable.new,
                              out: StringIO.new, encoder: "libx264").call(URL)
    end
  end

  def test_a_non_latin_youtube_title_fails_by_name_before_upload
    error = assert_raises(DigestVideo::Failure) do
      digest("id" => ID, "title" => "米津玄師 - 感電", "uploader" => "米津玄師", "webpage_url" => URL)
    end
    assert_match(/no R2 key for these credits .*key-safe/, error.message)
  end
end
