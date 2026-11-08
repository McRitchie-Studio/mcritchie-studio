require "test_helper"
require "support/msgraph_connect_fakes"

# [unit] Msgraph::Reader: the read-only Graph v1.0 calls (organization, users,
# Teams, root site, a site's drives) as Microsoft documents them, paging by
# @odata.nextLink, and Graph's error said plainly. Graph is a stand-in.
class Msgraph::ReaderTest < ActiveSupport::TestCase
  include MsgraphConnectFakes

  setup { msgraph_tokens([ 200, msgraph_grant(access_token: "tok") ]) }
  teardown { reset_msgraph_connect }

  def reader = Msgraph::Reader.new(store_msgraph)

  test "[unit] every read is a Graph v1.0 GET with the tenant's app-only token, and only one token is asked for" do
    with_msgraph_env do
      msgraph_reads_answer_everything
      r = reader
      org = r.organization
      users = r.users
      teams = r.teams
      site = r.root_site
      drives = r.drives(site.id)

      assert_equal "Synthetic Org", org.display_name
      assert_equal %w[Ada Bo], users.items.map(&:display_name)
      assert_equal "ada@synthetic.example", users.items.first.mail
      assert users.more?
      assert_equal [ "Shop" ], teams.items.map(&:display_name)
      assert_not teams.more?
      assert_equal "Home", site.display_name
      assert_equal [ "Documents" ], drives.items.map(&:name)
      assert_equal "documentLibrary", drives.items.first.drive_type

      assert_equal [
        "https://graph.microsoft.com/v1.0/organization/#{TENANT}",
        "https://graph.microsoft.com/v1.0/users?%24select=id%2CdisplayName%2CuserPrincipalName%2Cmail&%24top=100",
        "https://graph.microsoft.com/v1.0/teams",
        "https://graph.microsoft.com/v1.0/sites/root",
        "https://graph.microsoft.com/v1.0/sites/synthetic.sharepoint.example%2C1%2C2/drives"
      ], msgraph_read_requests.map(&:first)
      assert_equal [ "tok" ], msgraph_read_requests.map(&:last).uniq
      assert_equal 1, msgraph_token_requests.size
      assert_includes msgraph_token_requests.sole[:url], TENANT
    end
  end

  test "[unit] the next page follows Graph's own nextLink, and refuses a link off Graph" do
    with_msgraph_env do
      msgraph_reads("/users" => [ 200, { value: [ { id: "u3", displayName: "Cy" } ] } ])
      page = reader.users(next_link: "https://graph.microsoft.com/v1.0/users?$skiptoken=next")
      assert_equal [ "Cy" ], page.items.map(&:display_name)
      assert_equal "https://graph.microsoft.com/v1.0/users?$skiptoken=next", msgraph_read_requests.sole.first

      error = assert_raises(Msgraph::OAuthClient::Error) { reader.users(next_link: "https://evil.example/v1.0/users") }
      assert_match(/outside Microsoft Graph/, error.message)
      assert_equal 1, msgraph_read_requests.size, "the off-Graph link was never fetched"
    end
  end

  test "[unit] Graph's error is said with its message" do
    with_msgraph_env do
      msgraph_reads("/teams" => [ 403, { error: { code: "Forbidden", message: "Missing role permissions" } } ])
      error = assert_raises(Msgraph::OAuthClient::Error) { reader.teams }
      assert_equal "Microsoft Graph answered 403: Missing role permissions", error.message
    end
  end

  test "[unit] a tenant id reads before a row exists; nothing at all is refused" do
    with_msgraph_env do
      msgraph_reads("/organization/" => [ 200, ORGANIZATION ])
      assert_equal "Synthetic Org", Msgraph::Reader.new(tenant_id: TENANT).organization.display_name
      assert_raises(ArgumentError) { Msgraph::Reader.new }
    end
  end

  test "[unit] the reader has no write path: every request it can make is a GET" do
    source = File.read(Rails.root.join("app/services/msgraph/reader.rb"))
    assert_no_match(/Net::HTTP::(Post|Put|Patch|Delete)/, source)
    assert_includes source, "Net::HTTP::Get" # the control: the scan reads the real file
  end
end
