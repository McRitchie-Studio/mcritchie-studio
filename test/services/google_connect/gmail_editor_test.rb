require "test_helper"
require "support/google_connect_fakes"
require "support/gmail_editor_fake"

# [unit] GoogleConnect::GmailEditor (/tasks/gmail-organize-ability): the
# requests each action sends to Gmail, dry runs that send none, the audit log
# (GmailChange) and the refusals. A fake Gmail records every call; no test
# here reaches Google.
class GoogleConnect::GmailEditorTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  ORGANIZE = GoogleConnection::WRITE_ABILITIES.fetch(:gmail_organize)
  SCOPE_ORGANIZE = "openid email #{GMAIL} #{ORGANIZE.join(' ')}".freeze

  setup do
    @connection = store_google(email: "amcritchie@gmail.com", scope: SCOPE_ORGANIZE, abilities: %i[gmail gmail_organize], user: users(:viewer))
  end

  teardown do
    GoogleConnect::GmailEditor.http = nil
    GoogleConnect::OneClickUnsubscribe.http = nil
    GoogleConnect::OneClickUnsubscribe.resolver = nil
  end

  def editor_with(gmail)
    GoogleConnect::GmailEditor.http = gmail
    oauth = Struct.new(:token) { def access_token(_) = token }.new("ya29.synthetic")
    GoogleConnect::GmailEditor.new(@connection, requested_by: "pokemon", oauth:)
  end

  def ids(count) = (1..count).map { "m#{_1}" }

  test "[unit] a dry run counts the matches, sends no write and logs the run" do
    gmail = GmailEditorFake.new(ids: ids(3))
    result = editor_with(gmail).change(action: "archive", query: "from:news@example.com")

    assert_equal 3, result.matched
    assert_equal 0, result.changed
    assert_not result.applied
    assert_empty gmail.writes, "a dry run sends nothing that changes the mailbox"
    log = GmailChange.newest_first.first
    assert_equal [ "amcritchie@gmail.com", "archive", "from:news@example.com", 3, 0, false, "pokemon" ],
                 log.values_at(:mailbox, :action, :query, :matched_count, :changed_count, :applied, :requested_by)
  end

  test "[unit] each action sends the system labels it adds and removes" do
    expected = {
      "read" => [ [], %w[UNREAD] ], "unread" => [ %w[UNREAD], [] ], "archive" => [ [], %w[INBOX] ],
      "inbox" => [ %w[INBOX], [] ], "spam" => [ %w[SPAM], %w[INBOX] ], "not_spam" => [ %w[INBOX], %w[SPAM] ]
    }
    expected.each do |action, (add, remove)|
      gmail = GmailEditorFake.new(ids: ids(2))
      editor_with(gmail).change(action:, query: "in:inbox", apply: true)

      body = gmail.modifies.sole.last
      assert_equal [ ids(2), add, remove ], body.values_at("ids", "addLabelIds", "removeLabelIds"), action
    end
  end

  test "[unit] not_spam lists spam too, every other action does not" do
    gmail = GmailEditorFake.new(ids: ids(1))
    editor_with(gmail).change(action: "not_spam", query: "from:friend@example.com")
    assert_includes gmail.calls.first[1], "includeSpamTrash=true"

    gmail = GmailEditorFake.new(ids: ids(1))
    editor_with(gmail).change(action: "spam", query: "from:spammer@example.com")
    assert_not_includes gmail.calls.first[1], "includeSpamTrash"
  end

  test "[unit] label and move use the named label's id, matched without regard to case" do
    gmail = GmailEditorFake.new(ids: ids(2))
    editor_with(gmail).change(action: "move", query: "from:shop@example.com", label: "receipts", apply: true)

    assert_equal [ [ "Label_1" ], [ "INBOX" ] ], gmail.modifies.sole.last.values_at("addLabelIds", "removeLabelIds")
  end

  test "[unit] an applied label run creates a missing label; a dry run does not" do
    gmail = GmailEditorFake.new(ids: ids(1))
    dry = editor_with(gmail).change(action: "label", query: "from:bank@example.com", label: "Money")
    assert_empty gmail.writes
    assert_not dry.created_label

    result = editor_with(gmail).change(action: "label", query: "from:bank@example.com", label: "Money", apply: true)
    assert result.created_label
    created = gmail.writes.find { _1[1].end_with?("/labels") }
    assert_equal "Money", created.last["name"]
    assert_equal [ "Label_2" ], gmail.modifies.sole.last["addLabelIds"]
  end

  test "[unit] unlabel refuses a label the mailbox does not have" do
    gmail = GmailEditorFake.new(ids: ids(1))
    error = assert_raises(GoogleConnect::GmailEditor::Error) do
      editor_with(gmail).change(action: "unlabel", query: "in:inbox", label: "Nope", apply: true)
    end
    assert_match(/no label named "Nope"/, error.message)
    assert_empty gmail.writes
  end

  test "[unit] a system label such as TRASH is refused by name, in a run and in a filter" do
    gmail = GmailEditorFake.new(ids: ids(1), labels: [ { "id" => "TRASH", "name" => "TRASH", "type" => "system" } ])
    assert_raises(GoogleConnect::GmailEditor::Error) { editor_with(gmail).change(action: "label", query: "in:inbox", label: "trash", apply: true) }
    assert_raises(GoogleConnect::GmailEditor::Error) { editor_with(gmail).add_filter(query: "from:a@example.com", label: "TRASH", apply: true) }
    assert_empty gmail.writes
  end

  test "[unit] batches of 1000 and pages of 500 cover a large match" do
    gmail = GmailEditorFake.new(ids: ids(2_300))
    result = editor_with(gmail).change(action: "read", query: "is:unread", apply: true)

    assert_equal 2_300, result.changed
    assert_equal [ 1000, 1000, 300 ], gmail.modifies.map { _1.last["ids"].size }
    assert_equal 5, gmail.calls.count { _1[1].include?("/messages?") }
  end

  test "[unit] the limit stops a run and says so" do
    gmail = GmailEditorFake.new(ids: ids(1_200))
    result = editor_with(gmail).change(action: "archive", query: "older_than:1y", limit: 700, apply: true)

    assert_equal 700, result.changed
    assert result.capped
  end

  test "[unit] a run with no query, an unknown action or a missing label is refused before any call" do
    gmail = GmailEditorFake.new(ids: ids(1))
    editor = editor_with(gmail)
    assert_raises(GoogleConnect::GmailEditor::Error) { editor.change(action: "archive", query: "  ", apply: true) }
    assert_raises(GoogleConnect::GmailEditor::Error) { editor.change(action: "trash", query: "in:inbox", apply: true) }
    assert_raises(GoogleConnect::GmailEditor::Error) { editor.change(action: "move", query: "in:inbox", apply: true) }
    assert_empty gmail.calls
  end

  test "[unit] no action can trash or delete" do
    targets = GoogleConnect::GmailEditor::ACTIONS.values.flat_map { _1[:add] + _1[:remove] }
    assert_not_includes targets, "TRASH"
    source = Rails.root.join("app/services/google_connect/gmail_editor.rb").read
    assert_no_match(%r{/trash|Net::HTTP::Delete|batchDelete}, source)
  end

  test "[unit] a connection without Gmail organize is refused" do
    read_only = store_google(email: "reader@example.com", scope: "openid email #{GMAIL}", abilities: %i[gmail])
    error = assert_raises(GoogleConnect::GmailEditor::Error) { GoogleConnect::GmailEditor.new(read_only, requested_by: "pokemon") }
    assert_match(/has not turned on Gmail organize/, error.message)
  end

  test "[unit] a refusal from Google is logged with its message and raised" do
    gmail = GmailEditorFake.new(fail_with: 403)
    assert_raises(GoogleConnect::OAuthClient::Error) { editor_with(gmail).change(action: "archive", query: "in:inbox", apply: true) }

    assert_match(/Insufficient Permission/, GmailChange.newest_first.first.error)
  end

  test "[unit] a run Google stops part way logs the messages it did change" do
    gmail = GmailEditorFake.new(ids: ids(1_500))
    flaky = lambda do |method, url, token, body|
      next [ 500, { error: { message: "Backend Error" } }.to_json ] if url.end_with?("batchModify") && gmail.modifies.any?

      gmail.call(method, url, token, body)
    end
    assert_raises(GoogleConnect::OAuthClient::Error) { editor_with(flaky).change(action: "read", query: "is:unread", apply: true) }
    assert_equal [ 1_500, 1_000, true ], GmailChange.newest_first.first.values_at(:matched_count, :changed_count, :applied)
  end

  test "[unit] a filter is dry by default and sends the label, archive and mark-read actions on apply" do
    gmail = GmailEditorFake.new
    dry = editor_with(gmail).add_filter(query: "from:news@example.com", label: "Receipts", archive: true, mark_read: true)
    assert_nil dry["filter_id"]
    assert_empty gmail.writes

    added = editor_with(gmail).add_filter(query: "from:news@example.com", label: "Receipts", archive: true, mark_read: true, apply: true)
    assert_equal "filter-1", added["filter_id"]
    body = gmail.writes.sole.last
    assert_equal({ "query" => "from:news@example.com" }, body["criteria"])
    assert_equal({ "addLabelIds" => [ "Label_1" ], "removeLabelIds" => %w[INBOX UNREAD] }, body["action"])
    assert_equal [ "filter", 1, true ], GmailChange.newest_first.first.values_at(:action, :changed_count, :applied)
  end

  test "[unit] a filter with nothing to do is refused" do
    assert_raises(GoogleConnect::GmailEditor::Error) { editor_with(GmailEditorFake.new).add_filter(query: "from:a@example.com") }
  end

  # --- unsubscribe (/tasks/gmail-one-click-unsubscribe) -------------------

  ONE_CLICK = "List-Unsubscribe=One-Click".freeze

  # m1 and m2 from the same one-click sender; one sender of each other kind.
  def unsubscribe_mail
    GmailEditorFake.new(ids: %w[m1 m2 m3 m4 m5], headers: {
      "m1" => { "From" => "News <News@Shop.example>", "List-Unsubscribe" => "<mailto:u@shop.example>, <https://shop.example/u/1>", "List-Unsubscribe-Post" => ONE_CLICK },
      "m2" => { "From" => "News <news@shop.example>", "List-Unsubscribe" => "<https://shop.example/u/0>", "List-Unsubscribe-Post" => ONE_CLICK },
      "m3" => { "From" => "\"Blog\" <hi@blog.example>", "List-Unsubscribe" => "<https://blog.example/prefs>" },
      "m4" => { "From" => "list@club.example", "List-Unsubscribe" => "<mailto:leave@club.example>" },
      "m5" => { "From" => "Friend <friend@example.com>" }
    })
  end

  def stub_unsubscribe_post(status: 200)
    posts = []
    GoogleConnect::OneClickUnsubscribe.resolver = ->(_host) { [ "93.184.216.34" ] }
    GoogleConnect::OneClickUnsubscribe.http = lambda do |url, ip, body|
      posts << [ url, ip, body ]
      [ status, nil ]
    end
    posts
  end

  test "[unit] unsubscribe groups by sender, newest message first, and classifies each" do
    stub_unsubscribe_post
    gmail = unsubscribe_mail
    result = editor_with(gmail).unsubscribe(query: "category:promotions")

    rows = result.senders.map { _1.values_at("kind", "address", "name", "count") }
    assert_equal [ [ "one-click", "news@shop.example", "News", 2 ], [ "web-page", "hi@blog.example", "Blog", 1 ],
                   [ "email-only", "list@club.example", nil, 1 ], [ "none", "friend@example.com", "Friend", 1 ] ], rows
    assert_equal "https://shop.example/u/1", result.senders.first["uri"], "the newest message's URI"
    metadata = gmail.calls.select { _1[1].include?("format=metadata") }
    assert_equal 5, metadata.size
    assert_includes metadata.first[1], "metadataHeaders=List-Unsubscribe-Post"
  end

  test "[unit] an unsubscribe dry run sends no POST, writes nothing to Gmail and logs the run" do
    posts = stub_unsubscribe_post
    gmail = unsubscribe_mail
    result = editor_with(gmail).unsubscribe(query: "category:promotions")

    assert_not result.applied
    assert_empty posts
    assert_empty gmail.writes
    assert(result.senders.none? { _1.key?("outcome") })
    assert_equal [ [ "unsubscribe", "category:promotions", 5, 0, false ] ],
                 GmailChange.pluck(:action, :query, :matched_count, :changed_count, :applied)
  end

  test "[unit] an applied unsubscribe posts to the one-click sender only and logs it" do
    posts = stub_unsubscribe_post
    gmail = unsubscribe_mail
    result = editor_with(gmail).unsubscribe(query: "category:promotions", apply: true)

    assert_equal [ [ "https://shop.example/u/1", "93.184.216.34", "List-Unsubscribe=One-Click" ] ], posts
    assert_empty gmail.writes, "nothing is posted to Gmail, and no mail is sent"
    assert_equal [ "unsubscribed", "not unsubscribed (web-page)", "not unsubscribed (email-only)", "not unsubscribed (none)" ],
                 result.senders.map { _1["outcome"] }
    assert_equal [ [ "unsubscribe", "from:news@shop.example", 2, 1, true, nil ] ],
                 GmailChange.pluck(:action, :query, :matched_count, :changed_count, :applied, :error)
  end

  test "[unit] a failed one-click POST is logged with its status" do
    stub_unsubscribe_post(status: 503)
    result = editor_with(unsubscribe_mail).unsubscribe(query: "category:promotions", apply: true)

    assert_equal "failed: answered 503", result.senders.first["outcome"]
    assert_equal [ [ "from:news@shop.example", 0, true, "answered 503" ] ], GmailChange.pluck(:query, :changed_count, :applied, :error)
  end

  test "[unit] a one-click URI on a private address is refused and logged, never posted" do
    posts = stub_unsubscribe_post
    GoogleConnect::OneClickUnsubscribe.resolver = ->(_host) { [ "169.254.169.254" ] }
    result = editor_with(unsubscribe_mail).unsubscribe(query: "category:promotions", apply: true)

    assert_empty posts
    assert_match(/\Afailed: refused: .* private address/, result.senders.first["outcome"])
    assert_match(/private address/, GmailChange.sole.error)
  end

  test "[unit] unsubscribe needs a query and reads at most its limit" do
    gmail = unsubscribe_mail
    assert_raises(GoogleConnect::GmailEditor::Error) { editor_with(gmail).unsubscribe(query: " ") }
    assert_empty gmail.calls

    result = editor_with(gmail).unsubscribe(query: "category:promotions", limit: 2)
    assert result.capped
    assert_equal 2, result.matched
  end
end
