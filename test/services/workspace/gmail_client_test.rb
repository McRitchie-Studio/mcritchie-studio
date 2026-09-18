require "test_helper"

# [unit] Workspace::GmailClient — the query rule, the draft surface, and the
# absence that matters: no path from this object to a sent message.
class WorkspaceGmailClientTest < ActiveSupport::TestCase
  class ServiceDouble
    attr_reader :calls

    def initialize(raises: nil)
      @raises = Array(raises)
      @calls = []
    end

    def authorization=(_value); end

    def list_user_messages(user, **kwargs)
      @calls << [ :list_user_messages, user, kwargs ]
      raise @raises.shift if @raises.any?

      Struct.new(:messages, :next_page_token, keyword_init: true).new(messages: [], next_page_token: nil)
    end

    def get_user_message(user, id, **kwargs)
      @calls << [ :get_user_message, user, id, kwargs ]
      Struct.new(:id, :raw, keyword_init: true).new(id: id, raw: "cmF3")
    end

    def get_user_thread(user, id, **kwargs)
      @calls << [ :get_user_thread, user, id, kwargs ]
      Struct.new(:id).new(id)
    end

    def create_user_draft(user, draft)
      @calls << [ :create_user_draft, user, draft ]
      Struct.new(:id, :message, keyword_init: true).new(id: "d1", message: draft.message)
    end

    def update_user_draft(user, id, draft)
      @calls << [ :update_user_draft, user, id, draft ]
      Struct.new(:id, :message, keyword_init: true).new(id: id, message: draft.message)
    end

    def get_user_draft(user, id, **kwargs)
      @calls << [ :get_user_draft, user, id, kwargs ]
      Struct.new(:id).new(id)
    end
  end

  def client(service, sleeps: [])
    Workspace::GmailClient.new(service: service, sleeper: ->(s) { sleeps << s })
  end

  test "messages_list refuses a blank query rather than reading the whole mailbox" do
    service = ServiceDouble.new
    subject = client(service)

    [ nil, "", "  " ].each do |blank|
      assert_raises(Workspace::ApiRetry::Error) { subject.messages_list(query: blank) }
    end
    assert_empty service.calls, "a blank query must not reach Google at all"
  end

  test "messages_list puts the filter in the REQUEST" do
    service = ServiceDouble.new
    client(service).messages_list(query: "from:someone@example.test", cursor: "c", limit: 25)

    _name, user, kwargs = service.calls.first
    assert_equal "me", user
    assert_equal "from:someone@example.test", kwargs[:q]
    assert_equal "c", kwargs[:page_token]
    assert_equal 25, kwargs[:max_results]
  end

  test "metadata format asks only for the headers it names" do
    service = ServiceDouble.new
    client(service).messages_get("m1", format: "metadata")

    _name, _user, _id, kwargs = service.calls.first
    assert_equal "metadata", kwargs[:format]
    assert_equal Workspace::GmailClient::METADATA_HEADERS, kwargs[:metadata_headers]
    refute_includes Workspace::GmailClient::METADATA_HEADERS, "Body"
  end

  test "drafts_create hands the gem PLAIN MIME, because the gem owns the base64" do
    # representations.rb declares `property :raw, :base64 => true`, so the gem
    # encodes on the way out. Pre-encoding here double-encodes it, which no
    # service double can reveal — see test/integration/workspace_client_wiring_test.rb
    # for the assertion against the actual wire.
    service = ServiceDouble.new
    mime = "From: a@example.test\r\nSubject: hi\r\n\r\nbody"
    client(service).drafts_create(raw: mime)

    name, user, draft = service.calls.first
    assert_equal :create_user_draft, name
    assert_equal "me", user
    assert_equal mime, draft.message.raw
  end

  test "a draft can be tied to an existing thread, so a reply threads correctly" do
    service = ServiceDouble.new
    client(service).drafts_create(raw: "x", thread_id: "t42")

    _name, _user, draft = service.calls.first
    assert_equal "t42", draft.message.thread_id
  end

  test "drafts_update targets the draft id" do
    service = ServiceDouble.new
    client(service).drafts_update("d9", raw: "y")

    name, _user, id, = service.calls.first
    assert_equal :update_user_draft, name
    assert_equal "d9", id
  end

  test "FORBIDDEN_GEM_CALLS names both Gmail send paths, including the draft one" do
    # send_user_draft is the one that gets missed: a codebase that never sends a
    # MESSAGE can still post mail by sending the draft it just made.
    assert_equal %w[send_user_message send_user_draft].sort,
                 Workspace::GmailClient::FORBIDDEN_GEM_CALLS.sort

    # And they really are the gem's send surface — if a future gem renames them,
    # this fails rather than leaving the ban pointed at nothing.
    require "google/apis/gmail_v1"
    surface = Google::Apis::GmailV1::GmailService.instance_methods.map(&:to_s)
    Workspace::GmailClient::FORBIDDEN_GEM_CALLS.each do |call|
      assert_includes surface, call, "the ban list must name calls that exist to be banned"
    end
  end

  test "the client exposes no method that sends" do
    surface = Workspace::GmailClient.instance_methods(false).map(&:to_s)

    Workspace::GmailClient::FORBIDDEN_GEM_CALLS.each { |call| refute_includes surface, call }
    %w[send_message send_draft deliver deliver_now].each { |name| refute_includes surface, name }
  end

  test "draft_url points a human at the draft" do
    assert_equal "https://mail.google.com/mail/u/0/#drafts?compose=d1",
                 Workspace::GmailClient.draft_url("d1")
  end

  test "a throttle waits and then gives up" do
    throttle = Google::Apis::RateLimitError.new("rateLimitExceeded", status_code: 429,
                                                header: { "Retry-After" => "3" })
    service = ServiceDouble.new(raises: Array.new(8) { throttle })
    sleeps = []

    assert_raises(Workspace::ApiRetry::Error) { client(service, sleeps: sleeps).messages_list(query: "x") }
    assert_equal Array.new(Workspace::ApiRetry::MAX_RETRIES, 3), sleeps
  end
end
