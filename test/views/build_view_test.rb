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

  test "signed out, the composer opens the sign-in modal instead of leaving the page" do
    signed_in(nil)
    @draft = nil
    render template: "build/new"

    assert_select "[data-test='build-form'][x-data='buildComposer(false)']"
    assert_includes rendered, "Alpine.store('modals').open('auth'"
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

  test "signed out, a draft opens the standard sign-in modal and echoes their prompt" do
    signed_in(nil)
    @app_request = AppRequest.create!(prompt: "A client portal")
    render template: "build/show"

    assert_select "[data-test='build-echo']", text: "A client portal"
    register = css_select("[data-test='build-register']").first
    assert_includes register["x-init"], "$store.modals.open('auth'", "sign-in is the modal, not an inline form"
    assert_includes register["x-init"], build_request_path(@app_request.token), "the emailed link must return to this draft"
    assert_select "[data-test='build-register'] form", 0, "no inline sign-in form"
    assert_select "[data-test='build-open-auth']", 1
    assert_select "[data-test='build-claim']", 0
  end

  test "the auth modal card: Google, an email field, and returnTo passed to the magic link" do
    render partial: "modals/auth"

    assert_select "[data-test='auth-modal'] form[action='/auth/google_oauth2']"
    assert_select "[data-test='auth-email-form'] input#auth-email[type='email']"
    assert_includes rendered, "window.postMagicLink(this.email, this.props.returnTo)"
  end

  test "signed in, a draft asks for a name on the parent domain" do
    signed_in(users(:alex))
    @app_request = AppRequest.create!(prompt: "A client portal", user: users(:alex))
    render template: "build/show"

    field = css_select("[data-test='build-claim'] input[data-test='build-subdomain'][maxlength='30']").first
    assert field, "no name field"
    assert_nil field["placeholder"], "no static placeholder: the examples are typed into it"
    assert_equal "placeholderText", field[":placeholder"]
    assert_equal "onInput($el)", field["@input"], "input is cleaned as it is typed"
    assert_equal "focusWhenClear($el)", field["x-effect"], "focus lands once the modals close"
    assert_includes rendered, ".mcritchie.studio"
    AppRequest::EXAMPLE_NAMES.each { |example| assert_includes rendered, example }
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
