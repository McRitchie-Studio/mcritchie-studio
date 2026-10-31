# frozen_string_literal: true

# The conductor-machine half of `bin/release announce` (bin/lib/release_announce.rb):
# the smoke it runs on each production app, the hub snippet it sends, and the lines
# it prints. Pure: every HTTP answer here is a lambda.
#
#   ruby -Itest test/lib/release_announce_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/release_announce"

class ReleaseAnnounceTest < Minitest::Test
  def self.test(name, &block)
    define_method("test_#{name.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_|_\z/, '')}", &block)
  end

  TARGETS = [["mcritchie-studio", "https://mcritchie.studio"], ["turf-monster", "https://turfmonster.media"]].freeze

  test "[unit] smoke checks /up and home on every app and carries prod verify's SHA verdict" do
    seen = []
    http = ->(url) { seen << url; url == "https://turfmonster.media/up" ? "503" : "200" }
    verdicts = [{ "repo" => "turf-monster", "sha" => "abc1234", "ok" => false, "reason" => "runs def5678" }]
    smoke = ReleaseAnnounce.smoke(TARGETS, http_status: http, sha_verdicts: verdicts)

    assert_equal ["https://mcritchie.studio/up", "https://mcritchie.studio/", "https://turfmonster.media/up",
                  "https://turfmonster.media/"], seen
    assert ReleaseAnnounce.green?(smoke["mcritchie-studio"])
    refute ReleaseAnnounce.green?(smoke["turf-monster"])
    assert_equal({ "path" => "/up", "url" => "https://turfmonster.media/up", "code" => "503", "ok" => false },
                 smoke["turf-monster"]["checks"].first)
    assert_equal "runs def5678", smoke["turf-monster"]["sha"]["reason"]
    assert_nil smoke["mcritchie-studio"]["sha"]
  end

  test "[unit] no answer is not green" do
    smoke = ReleaseAnnounce.smoke(TARGETS.first(1), http_status: ->(_) { nil })
    refute ReleaseAnnounce.green?(smoke["mcritchie-studio"])
    assert_includes ReleaseAnnounce.smoke_lines(smoke).first, "/up no answer"
  end

  test "[unit] the hub snippet carries the slug, the smoke as JSON and the dry-run flag" do
    smoke = { "turf-monster" => { "checks" => [{ "path" => "/up", "code" => "200", "ok" => true }] } }
    ruby = ReleaseAnnounce.ruby("rel-x", smoke, dry_run: false)

    assert_includes ruby, 'Release.find_by!(slug: "rel-x")'
    assert_includes ruby, "Release::Conductor.announce_release(release: r, smoke: JSON.parse("
    assert_includes ruby, "dry_run: false"
    assert_equal smoke, JSON.parse(eval(ruby[/JSON\.parse\((".*?[^\\]")\)/, 1])) # rubocop:disable Security/Eval
    assert_includes ReleaseAnnounce.ruby("rel-x", smoke, dry_run: true), "dry_run: true"
  end

  test "[unit] the result lines end with the Exit Seam line, and an empty answer still says so" do
    lines = ReleaseAnnounce.result_lines({ "line" => "Slack posts: 3 sent / 1 failed",
                                           "posts" => [{ "what" => "general", "channel" => "C1", "soul" => "mason",
                                                         "status" => "failed", "error" => "Ambiguous: timeout" }] })
    assert_equal "  · slack general C1 as mason: failed — Ambiguous: timeout", lines.first
    assert_equal "  Slack posts: 3 sent / 1 failed", lines.last
    assert_equal ["  Slack posts: no answer from the hub"], ReleaseAnnounce.result_lines({})
  end
end
