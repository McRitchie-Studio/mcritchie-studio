require "test_helper"

# [integration] alex-build-funnel-handoff (folded into ritch-renamed-alex): /build
# greets the visitor as Alex, the AI build agent, and a sign-up that came from
# alex.build's CTAs is recorded on its request (AppRequest#origin), by a `ref` or
# `utm_source` naming alex.build, or by an alex.build referrer. A visit naming
# nothing, or naming something else, records nothing.
class BuildAlexOriginTest < ActionDispatch::IntegrationTest
  PROMPT = "A booking page for my barber shop".freeze

  def send_prompt
    post build_path, params: { app_request: { prompt: PROMPT } }
    AppRequest.recent.first
  end

  test "/build greets as Alex, an AI, with the mad-lad portrait, never Ritch" do
    get build_path

    assert_response :success
    assert_select "[data-test='build-form'] label", text: "Tell Alex what you want to build"
    assert_includes response.body, "AI build agent"
    assert_includes response.body, "/agents/alex.webp"
    refute_match(/\bRitch\b/, response.body)
  end

  test "a visitor from alex.build's CTA is recorded on the request it creates" do
    get build_path(ref: "alex.build")
    draft = send_prompt

    assert_equal "alex.build", draft.origin
    assert draft.from_alex_build?
  end

  test "a utm_source or an alex.build referrer counts the same, and the mark is spent once" do
    get build_path(utm_source: "alex-build", utm_medium: "cta")
    assert_equal "alex.build", send_prompt.origin

    assert_nil send_prompt.origin, "the session's origin is stamped on one request, then forgotten"

    get build_path, headers: { "Referer" => "https://www.alex.build/pricing" }
    assert_equal "alex.build", send_prompt.origin
  end

  test "no origin, another ref, or a look-alike host records nothing" do
    get build_path
    assert_nil send_prompt.origin

    get build_path(ref: "somewhere-else")
    assert_nil send_prompt.origin

    get build_path, headers: { "Referer" => "https://alex.build.evil.example/" }
    assert_nil send_prompt.origin
  end

  test "an admin sees which requests came from alex.build" do
    AppRequest.create!(prompt: "From alex.build", user: users(:viewer), origin: "alex.build").queue!("barber-book")
    AppRequest.create!(prompt: "From elsewhere", user: users(:viewer)).queue!("league-hub")
    log_in_as users(:alex)

    get build_requests_path

    assert_response :success
    assert_select "[data-test='app-request-origin']", 1
    assert_select "[data-test='app-request-origin']", text: "alex.build"
  end
end
