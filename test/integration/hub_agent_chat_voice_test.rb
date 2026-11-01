require "test_helper"

# [integration] /chat with Alex on the hub (task talk-to-alex-by-voice; epic
# .agents/epics/studio-voice.md, card 4): the engine agent chat answered
# in-process (HubAgentChatsController) on the admin's own chat:alex:<user id>
# thread, a spoken message's `voice` kept on the row and named by the server,
# and the page's [component] parts: the hold-to-talk recorder, the microphone
# chip, the approved privacy line, and the embedder only for a saved voice.
class HubAgentChatVoiceTest < ActionDispatch::IntegrationTest
  PRIVACY = "When you speak to an agent, your recording is sent to OpenAI to turn it into text, then deleted. We never keep the audio.".freeze

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    @alex = users(:alex)
  end

  teardown { AgentMessages::Answerers.reset! }

  def say(text, voice: nil, soul: "alex")
    post "/agent_chat/messages", params: { soul: soul, text: text, voice: voice }.compact, as: :json
  end

  test "[integration] a spoken message lands on the admin's chat:alex thread with voice named by the server" do
    log_in_as(@alex)
    say("Alex, what's on today?", voice: { speaker: "Someone Else Entirely", score: 0.91234, check: "matched", duration_ms: 2140 })

    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    row = AgentMessage.order(:id).last
    assert_equal "chat:alex:#{@alex.id}", row.thread_key
    assert_equal %w[web alex mcritchie-studio], [ row.channel, row.soul_slug, row.envelope["app"] ]
    assert_equal({ "speaker" => "Alex McRitchie", "score" => 0.9123, "check" => "matched", "duration_ms" => 2140 }, row.envelope["voice"])
    turn = response.parsed_body["turn"]
    assert_equal [ row.id, "user", "Alex, what's on today?" ], turn.values_at("id", "role", "text")
    assert_equal "Alex McRitchie", response.parsed_body.dig("voice", "speaker"), "the page shows the name the row kept"
  end

  test "[integration] an unrecognised voice is Someone new; a typed message carries no voice" do
    log_in_as(@alex)
    say("who am I?", voice: { speaker: "Alex McRitchie", check: "below_threshold", score: 0.2 })
    assert_equal "Someone new", AgentMessage.order(:id).last.envelope.dig("voice", "speaker")

    say("typed")
    assert_response :created
    assert_nil AgentMessage.order(:id).last.envelope["voice"]
    assert_nil response.parsed_body["voice"]
  end

  test "[integration] a malformed voice, a blank text and an unknown soul are refused" do
    log_in_as(@alex)
    assert_no_difference -> { AgentMessage.count } do
      say("hi", voice: { check: "trust_me" })
      assert_response :unprocessable_entity
      say("   ", voice: { check: "matched" })
      assert_response :unprocessable_entity
      say("hi", soul: "avi")
      assert_response :not_found
    end
  end

  test "[integration] turns reads the admin's own thread, the same one a satellite reaches" do
    log_in_as(@alex)
    say("first")
    id = response.parsed_body.dig("turn", "id")

    get "/agent_chat/turns", params: { soul: "alex" }
    assert_response :ok
    assert_includes response.parsed_body["turns"].map { |t| t["id"] }, id
    assert_equal true, response.parsed_body["pending"]

    get "/agent_chat/turns", params: { soul: "alex", after: id }
    assert_equal [], response.parsed_body["turns"]
  end

  test "[integration] behind the admin wall: a visitor gets 401, a signed-in viewer 403, and nothing is stored" do
    assert_no_difference -> { AgentMessage.count } do
      say("hi")
      assert_response :unauthorized
      post "/voice/takes", headers: { "Accept" => "application/json" }
      assert_response :unauthorized

      log_in_as(users(:viewer))
      say("hi")
      assert_response :forbidden
    end
  end

  test "[component] /chat renders the engine chat with hold to talk, the chip and the approved privacy line" do
    log_in_as(@alex)
    get "/chat"

    assert_response :ok
    assert_select "[data-studio-controller='agent-chat'][data-agent-chat-soul='alex']" do
      assert_select "form[data-agent-chat-form][action='/agent_chat/messages']"
    end
    assert_select "[data-test='voice-chat'][data-voice-chat-takes-url='/voice/takes'][data-voice-chat-soul='alex']" do
      assert_select "[data-studio-controller='voice-recorder'][data-voice-recorder-mode='hold']" do
        assert_select "[data-voice-recorder-label]", text: "Hold to talk"
      end
      assert_select "[data-studio-controller='microphone-chip']"
      assert_select "[data-voice-chat-status][role='status'][aria-live='polite']"
      assert_select "[data-test='voice-chat-privacy']", text: PRIVACY
    end
    assert_select "[data-voice-chat-embedder]", count: 0, message: "no saved voice: nothing to embed with"
  end

  test "[component] with a saved voice from the app's embedder, the page names that embedder" do
    model = Studio::VoiceMatch.model_id(Studio.voice_embedder)
    @alex.update!(voice_embedding: Array.new(256) { 0.0625 }, voice_embedding_model: model, voice_embedding_updated_at: Time.current)
    log_in_as(@alex)
    get "/chat"

    config = JSON.parse(css_select("[data-test='voice-chat']").first["data-voice-chat-embedder"])
    assert_equal [ Studio.voice_embedder, model ], config.values_at("name", "id")

    @alex.update!(voice_embedding_model: "an-older-model")
    get "/chat"
    assert_select "[data-voice-chat-embedder]", count: 0, message: "a saved voice from another model is never compared"
  end

  test "[component] the take endpoint answers the mock transcript for the admin" do
    log_in_as(@alex)
    audio = Rack::Test::UploadedFile.new(StringIO.new("not really audio"), "audio/webm", original_filename: "take")
    post "/voice/takes", params: { voice: { audio: audio, duration_ms: 1200, mime_type: "audio/webm;codecs=opus" } }

    assert_response :ok
    assert_equal [ Studio::VoiceTranscription::Mock::DEFAULT_TEXT, "Someone new", "no_embedding", 1200 ],
                 response.parsed_body.values_at("text", "speaker", "check", "duration_ms")
  end

  test "[unit] the privacy page carries the approved line verbatim" do
    get "/privacy"
    assert_response :ok
    assert_select "[data-test='voice-message-privacy']", text: /#{Regexp.escape(PRIVACY)}/
    assert_equal PRIVACY, VoiceChatHelper::VOICE_PRIVACY
  end
end
