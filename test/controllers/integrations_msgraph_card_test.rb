require "test_helper"
require "support/msgraph_connect_fakes"

# [component] The /integrations Microsoft 365 card is dark: only an admin's page
# lists it, in Connect, Coming soon, with the hub's own tenant connections and a
# Connect disabled until the server can take one. No tenant id renders.
class IntegrationsMsgraphCardTest < ActionDispatch::IntegrationTest
  include MsgraphConnectFakes

  CARD = "[data-test='integration-entry'][data-entry='microsoft_365']".freeze
  SLOT = "#{CARD} [data-test='entry-action'] [data-test='msgraph-connection']".freeze

  teardown { reset_msgraph_connect }

  test "[component] the card is dark: signed out or not an admin, the page does not list it" do
    get integrations_path
    assert_select CARD, 0
    assert_no_match(/Microsoft 365/, response.body)

    log_in_as users(:viewer)
    get integrations_path
    assert_select CARD, 0
    assert_select "[data-test='integration-entry'][data-entry='fathom']" # the control: the page rendered its cards
  end

  test "[component] an admin sees Connect disabled until MSGRAPH_CLIENT_ID and MSGRAPH_CLIENT_SECRET are set" do
    log_in_as users(:alex)
    with_msgraph_env(creds: false) do
      get integrations_path
      assert_select "#{SLOT}[data-state='none'][data-connectable='false']"
      assert_select "#{SLOT} button[data-test='msgraph-connect-disabled'][disabled]", text: "Connect Microsoft 365"
      assert_select "#{SLOT} [data-test='msgraph-connect']", 0
      assert_select "[data-test='integration-group'][data-group='connect'] #{CARD}[data-status='soon'] [data-test='coming-soon']"
    end
  end

  test "[component] once configured, an admin's card links Connect back to /integrations and names each connected tenant" do
    log_in_as users(:alex)
    with_msgraph_env do
      get integrations_path
      assert_select "#{SLOT} a[data-test='msgraph-connect'][href='#{admin_msgraph_connect_path(return_to: integrations_path)}']"

      store_msgraph
      get integrations_path
      assert_select "#{SLOT}[data-state='connected'] [data-test='msgraph-tenants']", text: /Synthetic Org/
      assert_select "#{SLOT} [data-test='msgraph-manage'][href='#{admin_msgraph_path}']"
      assert_no_match(/#{TENANT}/i, response.body)
    end
  end
end
