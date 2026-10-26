require "test_helper"
require_relative "../support/client_cto_fixtures"

# [integration] The CTO avatar bank end to end (task cto-animal-avatar-bank,
# Alex McRitchie 2026-10-20): /build's "New set", an animal chosen at /build showing in the
# app's CTO chat, an older portrait still showing, and the owner re-picking the
# avatar from the chat, which an avatar ask opens in code (no model).
class CtoAvatarPickerTest < ActionDispatch::IntegrationTest
  include ClientCtoFixtures

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    AgentPerson.seed_owner!
    @owner = User.create!(email: "owner@example.test", first_name: "Pat", name: "Pat")
  end

  teardown { AgentMessages::Answerers.reset! }

  def launch!(avatar)
    request = AppRequest.create!(prompt: "A booking site for my groomer", user: @owner)
    AppLaunch.new(request, subdomain: "pawsome", intake: client_intake(cto_avatar: avatar)).call!
    request
  end

  def open_chat(user = @owner)
    log_in_as(user)
    get chat_application_path("pawsome")
    get chat_application_path("pawsome") if response.body.include?("data-test=\"build-launch\"")
    assert_response :success
  end

  def send_chat(text)
    post chat_application_path("pawsome"), params: { cto_chat: { text: text, client_id: SecureRandom.hex(8) } }, as: :turbo_stream
    assert_response :success
    AgentMessage.where(channel: "web", channel_ref: "pawsome").order(:id).last
  end

  test "[integration] New set: the next set is drawn in the request's palette, led by the pick, with none of the set on screen" do
    request = AppRequest.create!(prompt: "A booking site", palette: PALETTE.merge("name" => "Pitch"))
    shown = BuildIntake::Animals.sample(keep: "animal:fox")
    get build_request_cto_animals_path(request.token), params: { keep: "animal:fox", except: shown }
    assert_response :success
    values = css_select("input[name='portrait']").map { |input| input["value"] }
    assert_equal BuildIntake::Animals::SET_SIZE, values.size
    assert_equal "animal:fox", values.first
    assert_select "input[value='animal:fox'][checked]"
    assert_empty values.drop(1) & shown
    assert_equal values.uniq, values
    fox = BuildIntake::Animals.colors("animal:fox", request.palette)
    assert_select "svg[data-animal=fox][style*='#{fox['light']['bg']}'][style*='#{fox['dark']['fg']}']"

    # A junk pick is dropped, not echoed.
    get build_request_cto_animals_path(request.token), params: { keep: "<script>", except: "nope" }
    assert_response :success
    assert_select "input[checked]", 0
    refute_includes response.body, "<script>"

    # A request that belongs to someone else is not theirs to read.
    request.update!(user: @owner)
    get build_request_cto_animals_path(request.token)
    assert_redirected_to build_path
  end

  test "[integration] the animal chosen at /build is the CTO's portrait in its chat, the launch panel and the being-built page" do
    launch!("animal:otter")
    assert_equal "animal:otter", App.find_by!(slug: "pawsome").client_cto.portrait
    log_in_as(@owner)
    get chat_application_path("pawsome")
    assert_select "[data-test=build-launch] svg[data-test=client-cto-portrait][data-animal=otter]"
    get chat_application_path("pawsome")
    otter = BuildIntake::Animals.colors("animal:otter", PALETTE)
    assert_select "[data-test=agent-portrait] svg[data-test=client-cto-portrait][data-animal=otter][aria-label=Nova][style*='#{otter['light']['bg']}']"

    page = ClientApps::BeingBuilt.for("pawsome", App.find_by!(slug: "pawsome"))
    assert_includes page.portrait_svg, "prefers-color-scheme: dark"
    assert_includes page.portrait_svg, otter["dark"]["bg"]
  end

  test "[integration] an app with an older portrait keeps it" do
    launch!("harbor")
    open_chat
    assert_select "[data-test=agent-portrait] img[data-test=client-cto-portrait][src*='cto_portraits/harbor']"
    assert_select "[data-test=agent-portrait] svg.cto-animal", 0
    assert_equal "harbor", AppCto.find_by!(app_slug: "pawsome").portrait
    # The picker leads with it, so a save without a new pick keeps it.
    assert_select "[data-test=cto-chat-avatar-form] input[name=portrait][value=harbor][checked]"
  end

  test "[integration] an owner's avatar ask is answered in code with the picker, and the pick saves everywhere" do
    request = launch!("animal:otter")
    open_chat
    assert_select "[data-test=cto-chat-page][data-cto-avatar-picker]"
    assert_select "[data-test=cto-chat-avatar-head][data-cto-avatar-open][aria-haspopup=dialog]"
    assert_select "[data-test=cto-chat-avatar-form][data-build-portrait-save] dialog[data-test=build-portrait-dialog]" do
      assert_select "input[name=portrait]", BuildIntake::Animals::SET_SIZE
      assert_select "input[name=portrait][value='animal:otter'][checked]"
      assert_select "[data-test=build-portrait-shuffle][data-build-portrait-shuffle='#{chat_avatars_application_path('pawsome')}']"
      assert_select "[data-test=build-portrait-credit]", /Fluent Emoji by Microsoft, MIT/
    end

    reply = nil
    assert_no_difference -> { AgentMessage.where(status: "received").count }, "no model is asked" do
      assert_enqueued_with(job: AgentMessageReplyJob) { reply = send_chat("Can you change your avatar to something cooler?") }
    end
    assert_equal [ "completed", "avatar picker", true ], [ reply.status, reply.action_summary, reply.run_meta["avatar_picker"] ]
    assert_equal AgentMessages::AvatarAsk::REPLY, reply.response_text
    refute_match(/#\h{6}|follow up/i, reply.response_text, "no hex colours, no human follow-up")
    get chat_application_path("pawsome")
    assert_select "#cto-chat-turn-#{reply.id} [data-test=cto-chat-avatar-pick][data-cto-avatar-open]", AgentMessages::AvatarAsk::BUTTON

    get chat_avatars_application_path("pawsome"), params: { keep: "animal:otter" }
    assert_response :success
    assert_select "input[name=portrait][value='animal:otter'][checked]"

    patch chat_avatar_application_path("pawsome"), params: { portrait: "animal:fox" }
    assert_redirected_to chat_application_path("pawsome")
    assert_equal "animal:fox", AppCto.find_by!(app_slug: "pawsome").portrait
    assert_equal "animal:fox", request.reload.cto_avatar, "the launching request follows"
    follow_redirect!
    assert_select "[data-test=agent-portrait] svg[data-test=client-cto-portrait][data-animal=fox]"

    patch chat_avatar_application_path("pawsome"), params: { portrait: "animal:pikachu" }
    assert_redirected_to chat_application_path("pawsome")
    assert_equal "animal:fox", AppCto.find_by!(app_slug: "pawsome").portrait, "an unknown pick changes nothing"
  end

  test "[integration] the picker saves by JSON: the head's new portrait and a line to announce; a refusal or a failure answers an error it can show" do
    request = launch!("animal:otter")
    open_chat
    assert_select "[data-test=cto-chat-avatar-form][data-current-avatar='animal:otter'] [data-test=cto-chat-avatar-announce][role=status][aria-live=polite]"
    assert_select "[data-test=cto-chat-avatar-form] [data-test=build-portrait-status][role=status]"

    patch chat_avatar_application_path("pawsome"), params: { portrait: "animal:fox" }, as: :json
    assert_response :success
    body = response.parsed_body
    assert_equal [ true, "animal:fox", "Saved. Nova's new look: Fox." ], body.values_at("ok", "avatar", "message")
    assert_includes body["portrait_html"], %(data-animal="fox")
    assert_includes body["portrait_html"], %(data-test="client-cto-portrait")
    assert_equal "animal:fox", AppCto.find_by!(app_slug: "pawsome").portrait

    patch chat_avatar_application_path("pawsome"), params: { portrait: "animal:pikachu" }, as: :json
    assert_response :unprocessable_entity
    assert_equal({ "ok" => false, "error" => "Pick one of the avatars." }, response.parsed_body)

    # A failed write is logged (rescue_and_log) and answered, never a bare 500 page.
    failing = ->(*) { raise ActiveRecord::StatementInvalid, "boom" }
    assert_difference -> { ErrorLog.count }, 1 do
      AppRequest.stub(:holding, failing) do
        patch chat_avatar_application_path("pawsome"), params: { portrait: "animal:owl" }, as: :json
      end
    end
    assert_response :internal_server_error
    assert_equal false, response.parsed_body["ok"]
    assert_match(/did not save/, response.parsed_body["error"])
    assert_equal "animal:fox", AppCto.find_by!(app_slug: "pawsome").portrait, "the transaction rolled back"
    assert_equal "animal:fox", request.reload.cto_avatar
  end

  test "[integration] an ordinary message still goes to the model" do
    launch!("animal:otter")
    open_chat
    message = send_chat("Can we add a waitlist?")
    assert_equal "received", message.status
  end

  test "[integration] nobody but the owner may re-pick: an admin reads the chat without the picker, a stranger gets a 404" do
    launch!("animal:otter")
    admin = User.create!(email: "admin@example.test", first_name: "Ada", name: "Ada", role: "admin")
    open_chat(admin)
    assert_select "[data-test=cto-chat-page][data-cto-avatar-picker]", 0
    assert_select "[data-test=cto-chat-avatar-form]", 0
    assert_select "[data-test=cto-chat-avatar-head]", 0
    patch chat_avatar_application_path("pawsome"), params: { portrait: "animal:fox" }
    assert_response :not_found
    get chat_avatars_application_path("pawsome")
    assert_response :not_found

    stranger = User.create!(email: "stranger@example.test", first_name: "Sam", name: "Sam")
    log_in_as(stranger)
    patch chat_avatar_application_path("pawsome"), params: { portrait: "animal:fox" }
    assert_response :not_found
    assert_equal "animal:otter", AppCto.find_by!(app_slug: "pawsome").portrait
  end
end
