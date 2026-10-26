require "test_helper"
require "support/fathom_connect_fakes"

# [unit] Fathom::Reader: a page of meetings and its cursor, the newest meeting,
# one transcript and one summary, each a GET with the bearer token one refresh
# answered. Fathom is a stand-in throughout.
class Fathom::ReaderTest < ActiveSupport::TestCase
  include FathomConnectFakes

  teardown { reset_fathom_connect }

  def reader
    with_fathom_env { fathom_tokens([ 200, fathom_grant(access_token: "a-page") ]) }
    Fathom::Reader.new(store_fathom)
  end

  test "[unit] reader lists meetings and reads one transcript" do
    fathom_reads_answer_everything
    r = reader

    page = with_fathom_env { r.meetings }
    assert_equal [ 9, 7 ].sort, page.meetings.map(&:recording_id).sort
    assert_equal "cur-2", page.next_cursor
    assert page.more?
    assert_equal "Older call", page.meetings.find { _1.recording_id == 7 }.title, "meeting_title when there is no title"

    newest = r.newest(page)
    assert_equal "Lender call", newest.title
    assert_equal Time.utc(2026, 10, 14, 16), newest.created_at

    transcript = r.transcript(newest.recording_id)
    assert_equal 3, transcript.lines.size
    assert_equal %w[Alex McRitchie Lender], transcript.speakers
    assert_equal "Morning, Alex McRitchie.", transcript.lines.second.text

    assert_equal "## Lender call\n\n- Term sheet agreed.", r.summary(9)

    assert_equal [ "#{Fathom::Reader::API_URL}/meetings", "#{Fathom::Reader::API_URL}/recordings/9/transcript", "#{Fathom::Reader::API_URL}/recordings/9/summary" ],
                 fathom_read_requests.map(&:first)
    assert_equal [ "a-page" ], fathom_read_requests.map(&:last).uniq, "every read carries the one refreshed token"
    assert_equal 1, fathom_token_requests.size, "one refresh per Reader"
  end

  test "[unit] the next page passes the cursor, and a last page has no more" do
    fathom_reads("/meetings" => [ 200, { items: [], next_cursor: nil } ])
    page = reader.meetings(cursor: "cur 2")

    assert_equal "#{Fathom::Reader::API_URL}/meetings?cursor=cur+2", fathom_read_requests.sole.first
    assert_not page.more?
    assert_nil reader.newest(page)
  end

  test "[unit] a reader given an access token spends no refresh" do
    fathom_reads_answer_everything
    fathom_tokens
    Fathom::Reader.new(token: "from-exchange").meetings

    assert_empty fathom_token_requests
    assert_equal "from-exchange", fathom_read_requests.sole.last
  end

  test "[unit] Fathom's error is said plainly" do
    fathom_reads("/meetings" => [ 429, { message: "Rate limit exceeded" } ])

    error = assert_raises(Fathom::OAuthClient::Error) { reader.meetings }
    assert_equal "Fathom answered 429: Rate limit exceeded", error.message
  end
end
