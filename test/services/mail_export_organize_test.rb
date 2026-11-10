require "test_helper"
require "support/google_connect_fakes"
require "support/gmail_editor_fake"

# [integration] MailExport's organize verbs, the dyno half of
# `bin/mail organize|filter|labels|filters` (/tasks/gmail-organize-ability):
# the request a CLI run sends, through GmailEditor, to a fake Gmail and the
# GmailChange log. Dry first, then applied; refusals come back as errors.
class MailExportOrganizeTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  ORGANIZE = GoogleConnection::WRITE_ABILITIES.fetch(:gmail_organize)

  setup do
    @gmail = GmailEditorFake.new(ids: %w[m1 m2 m3])
    GoogleConnect::GmailEditor.http = @gmail
    GoogleConnect::OAuthClient.sign_in_stand_in = Struct.new(:x) { def access_token(_) = "ya29.synthetic" }.new
  end

  teardown do
    GoogleConnect::GmailEditor.http = nil
    GoogleConnect::OAuthClient.sign_in_stand_in = nil
  end

  def connect(email, scope:, abilities:)
    store_google(email:, scope: "openid email #{scope}", abilities:, user: users(:viewer))
  end

  def organize(**over)
    MailExport.call({ "verb" => "organize", "mailbox" => "amcritchie@gmail.com", "by" => "pokemon",
                      "action" => "archive", "query" => "from:news@example.com" }.merge(over.transform_keys(&:to_s)))
  end

  test "[integration] organize runs dry, then applies, and logs both" do
    connect("amcritchie@gmail.com", scope: "#{GMAIL} #{ORGANIZE.join(' ')}", abilities: %i[gmail gmail_organize])

    dry = organize
    assert_equal [ 3, 0, false ], dry["result"].values_at("matched", "changed", "applied")
    assert_empty @gmail.writes

    applied = organize(apply: true)
    assert_equal [ 3, 3, true ], applied["result"].values_at("matched", "changed", "applied")
    assert_equal [ false, true ], GmailChange.for_mailbox("amcritchie@gmail.com").order(:id).pluck(:applied)
  end

  test "[integration] a mailbox without organize, or not connected, answers an error and changes nothing" do
    connect("amcritchie@gmail.com", scope: GMAIL, abilities: %i[gmail])

    assert_match(/has not turned on Gmail organize/, organize(apply: true)["error"])
    assert_match(/is not connected/, organize(mailbox: "nobody@example.com", apply: true)["error"])
    assert_match(/need --mailbox/, organize(mailbox: "", apply: true)["error"])
    assert_empty @gmail.calls
    assert_equal 0, GmailChange.count
  end

  test "[integration] labels, filters and filter answer through the same connection" do
    connect("amcritchie@gmail.com", scope: "#{GMAIL} #{ORGANIZE.join(' ')}", abilities: %i[gmail gmail_organize])
    base = { "mailbox" => "amcritchie@gmail.com", "by" => "pokemon" }

    assert_equal [ "Receipts" ], MailExport.call(base.merge("verb" => "labels"))["labels"].map { _1["name"] }
    assert_equal [ { "id" => "filter-1" } ], MailExport.call(base.merge("verb" => "filters"))["filters"]
    filter = MailExport.call(base.merge("verb" => "filter", "query" => "from:a@example.com", "archive" => true, "apply" => true))["filter"]
    assert_equal "filter-1", filter["filter_id"]
  end
end
