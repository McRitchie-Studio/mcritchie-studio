# frozen_string_literal: true

require "test_helper"
require_relative "../lib/release_cli_harness"

# [integration] `bin/release status` prints the sentences the Next Release card
# shows. The loop is run for real, with only the transport stood in: the CLI's own
# board snippet is captured, evaluated here against this database, and its answer
# handed back to the CLI, whose output is then compared with the rendered card.
class ReleaseStatusLaneTest < ActionDispatch::IntegrationTest
  # The subprocess runner the bin/release CLI suite uses (sealed PATH, no board).
  class Cli < ReleaseCliHarness; end
  GIT_STUB = %(def ladder_ahead_states = { "release" => [], "accepted" => [], "unreadable" => [] }\n)

  setup { log_in_as(users(:alex)) }

  setup do
    Release.delete_all
    ReleaseConductorClaim.delete_all
    SessionMascot.delete_all
    @cli = Cli.new("release_status_lane")
  end

  # What `bin/release status` sends to the board.
  def status_snippet
    out = @cli.run_cli(["status"], call: "status", setup: GIT_STUB + <<~RUBY)
      def conductor(ruby, read_only: false)
        puts("SNIPPET=" + [ruby].pack("m0"))
        { "pending" => [], "accepted" => [], "release" => nil }
      end
    RUBY
    out[/^\s*SNIPPET=(\S+)/, 1].unpack1("m0")
  end

  # The board's answer to that snippet, from this database.
  def board_answer(snippet)
    printed, = capture_io { eval(snippet, TOPLEVEL_BINDING.dup, "bin/release status snippet") } # rubocop:disable Security/Eval
    JSON.parse(printed.lines.reverse.find { |line| line.strip.start_with?("{") })
  end

  def status_output(answer)
    @cli.run_cli(["status"], call: "status",
                             setup: GIT_STUB + "def conductor(ruby, read_only: false) = #{answer.inspect}\n")
  end

  def card_sentences
    get deployments_path
    css_select("#current-release [data-test='release-lane-sentence']").map { |node| node["title"] }
  end

  test "[integration] bin/release status prints the card's sentences, in the card's order" do
    release = Release.open!
    release.add(Task.create!(title: "status lane first member task", stage: "reviewed"))
    ReleaseConductorClaim.acquire(release_slug: release.slug, role: "assembler", session: "sess-assembler-9b57",
                                  nonce: "n", soul: "steffon", label: "Onix")
    release.record_event!(step: "ship_authorized", status: "started", source: "conductor",
                          metadata: { "mode" => "timed", "window_ends_at" => 30.minutes.from_now.utc.iso8601,
                                      "window_minutes" => 30 })
    release.grant_ship_authorization!(actor: users(:alex).email, source: "web")
    late = Task.create!(title: "status lane late member task", stage: "reviewed")
    release.add(late)

    answer = board_answer(status_snippet)
    out = status_output(answer)
    card = card_sentences

    assert_equal 5, card.size, "assembler, deployer, and three grant sentences"
    assert_includes card, "Joined after approval: #{late.slug}."
    printed = out.lines.map(&:strip)
    positions = card.map { |sentence| printed.index(sentence) }
    refute_includes positions, nil, "every card sentence is printed verbatim:\n#{out}"
    assert_equal positions.sort, positions, "in the card's order"
    assert_operator positions.first, :>, printed.index("current release: #{release.slug} (assembling)")
  end

  test "[integration] with no release, status names a prepare that is forming the next one" do
    ReleaseConductorClaim.acquire(release_slug: ReleaseConductorClaim::FORMING_SLUG, role: "assembler",
                                  session: "sess-forming-77aa", nonce: "n", label: "Onix")

    answer = board_answer(status_snippet)
    out = status_output(answer)

    assert_nil answer["release"]
    assert_includes out, "current release: none active"
    assert_match(/Onix \(session …77aa\) is assembling the next release since/, out)
  end
end
