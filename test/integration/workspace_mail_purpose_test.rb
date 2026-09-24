require "test_helper"
require "faraday"
require "google/apis/gmail_v1"
require "google/apis/drive_v3"

# [integration] The drafting lane's two hardening guarantees, across real
# boundaries rather than doubles:
#
#   1. PURPOSE. A mailbox row (alex@) opens that address's mail and never its
#      Drive. Exercised through the REAL clients building REAL authorizers from
#      a synthetic service-account key: GmailClient must get one, DriveClient
#      must be refused — the grant would allow both, so only our code can say no.
#   2. PAGING. "One thread or several" is decided from every page. Exercised
#      through the real google-apis gem on a stubbed transport, so the
#      nextPageToken -> pageToken round trip is what the gem actually sends.
class WorkspaceMailPurposeTest < ActionDispatch::IntegrationTest
  def self.signing_key = @signing_key ||= OpenSSL::PKey::RSA.new(2048)

  def key_json
    { "type" => "service_account", "project_id" => "synthetic-project", "private_key_id" => "abc123",
      "private_key" => self.class.signing_key.to_pem,
      "client_email" => "synthetic-sa@synthetic-project.iam.gserviceaccount.com",
      "client_id" => "100000000000000000000" }.to_json
  end

  setup do
    @original_env = ENV["GOOGLE_SERVICE_ACCOUNT_JSON"]
    ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = key_json
    Workspace::Credentials.reset!
    account = WorkspaceAccount.create!(domain: "purpose.test")
    account.mark_verified!
    account.workspace_mailboxes.create!(address: "alex@purpose.test").mark_verified!
  end

  teardown do
    @original_env ? ENV["GOOGLE_SERVICE_ACCOUNT_JSON"] = @original_env : ENV.delete("GOOGLE_SERVICE_ACCOUNT_JSON")
    Workspace::Credentials.reset!
  end

  test "the real Gmail client impersonates a mailbox; the real Drive client refuses it" do
    gmail = Workspace::GmailClient.new(subject: "alex@purpose.test").service
    assert_equal "alex@purpose.test", gmail.authorization.sub

    assert_raises(Workspace::Credentials::UnregisteredSubject) do
      Workspace::DriveClient.new(subject: "alex@purpose.test").service
    end
    assert_equal "team@purpose.test", Workspace::DriveClient.new(subject: "team@purpose.test").service.authorization.sub,
      "the workspace's own subject still reaches Drive"
  end

  test "a second thread on page two is found through the real gem's paging" do
    requests = []
    connection = Faraday.new do |builder|
      builder.adapter :test do |stub|
        stub.get(%r{/gmail/v1/users/me/messages}) do |env|
          token = Rack::Utils.parse_nested_query(env.url.query.to_s)["pageToken"]
          requests << token
          body = if token.nil?
                   { "messages" => [ { "id" => "m1", "threadId" => "t-long" }, { "id" => "m2", "threadId" => "t-long" } ],
                     "nextPageToken" => "page-2" }
          else
                   { "messages" => [ { "id" => "m3", "threadId" => "t-other" } ] }
          end
          [ 200, { "Content-Type" => "application/json" }, body.to_json ]
        end
      end
    end
    service = Google::Apis::GmailV1::GmailService.new
    service.authorization = "ya29.test-bearer"
    service.client = connection
    client = Workspace::GmailClient.new(service: service, sleeper: ->(_s) { })

    assert_raises(Workspace::ThreadFinder::Ambiguous) do
      Workspace::ThreadFinder.new(client).thread_id_for("from:vendor.test")
    end
    assert_equal [ nil, "page-2" ], requests, "page two was requested with the token page one returned"
  end
end
