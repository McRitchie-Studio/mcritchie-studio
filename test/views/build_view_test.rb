# frozen_string_literal: true

require "test_helper"

# [component] The /build views in isolation: the chat-style composer, and the
# request page's three states — register (signed out), claim a name (signed in,
# draft), and the status page once queued.
class BuildViewTest < ActionView::TestCase
  include ApplicationHelper

  def signed_in(user)
    view.define_singleton_method(:logged_in?) { !user.nil? }
    view.define_singleton_method(:current_user) { user }
  end

  test "the composer: a labelled prompt, Enter-to-send, a send button and examples" do
    signed_in(nil)
    @draft = nil
    render template: "build/new"

    assert_select "[data-test='build-form'] textarea[name='app_request[prompt]'][maxlength='#{AppRequest::PROMPT_LIMIT}'][required]"
    assert_select "label.sr-only", text: "Describe your app"
    assert_select "[data-test='build-send'][aria-label='Send']"
    assert_includes rendered, "@keydown.enter", "Enter must send the prompt"
    assert_select "[data-test='build-examples'] button", 4
  end

  test "signed out, a draft asks the visitor to register and echoes their prompt" do
    signed_in(nil)
    @app_request = AppRequest.create!(prompt: "A client portal")
    render template: "build/show"

    assert_select "[data-test='build-echo']", text: "A client portal"
    assert_select "[data-test='build-register'] form[action='/auth/google_oauth2']"
    assert_includes rendered, @app_request.token, "the emailed link must return to this draft"
    assert_select "[data-test='build-claim']", 0
  end

  test "signed in, a draft asks for a name on the parent domain" do
    signed_in(users(:alex))
    @app_request = AppRequest.create!(prompt: "A client portal", user: users(:alex))
    render template: "build/show"

    assert_select "[data-test='build-claim'] input[data-test='build-subdomain'][maxlength='30']"
    assert_includes rendered, ".mcritchie.studio"
    assert_select "[data-test='build-register']", 0
  end

  test "queued, the page shows the reserved address and the first step done" do
    signed_in(users(:alex))
    @app_request = AppRequest.create!(prompt: "A client portal", user: users(:alex)).queue!("client-portal")
    render template: "build/show"

    assert_select "[data-test='build-host']", text: "client-portal.mcritchie.studio"
    assert_select "[data-test='build-steps'] [data-step='queued'][data-done='true']"
    assert_select "[data-test='build-steps'] [data-step='live'][data-done='false']"
  end
end
