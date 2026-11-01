require "test_helper"

# [unit] The hub's voice wiring (config/initializers/studio.rb; task
# talk-to-alex-by-voice): POST /voice/takes is on, /chat may render the engine
# chat with Alex, the key is voice's own, QA runs the mock, and production with
# no voice key never reaches the hub's shared OPENAI_API_KEY.
class HubVoiceConfigTest < ActiveSupport::TestCase
  test "transcription and the Alex chat are on, and the take route is drawn" do
    assert Studio.voice_transcription
    assert Studio.voice_profile
    assert_equal %w[alex], Studio.agent_chat_soul_list
    assert_equal "/voice/takes", Rails.application.routes.url_helpers.studio_voice_takes_path
    assert_equal "mock", Studio::VoiceTranscription.adapter_name, "tests never reach the vendor"
  end

  test "the key is STUDIO_VOICE_OPENAI_API_KEY, never OPENAI_API_KEY" do
    assert_equal "sk-voice", HubVoiceConfig.api_key(env: { "STUDIO_VOICE_OPENAI_API_KEY" => " sk-voice " })
    assert_nil HubVoiceConfig.api_key(env: { "OPENAI_API_KEY" => "sk-image" })
    assert_nil HubVoiceConfig.api_key(env: { "STUDIO_VOICE_OPENAI_API_KEY" => "  " })
  end

  test "QA runs the mock transcriber, whatever else is set" do
    assert_equal "mock", HubVoiceConfig.transcriber(env: {}, production: true, qa: true)
    assert_equal "mock", HubVoiceConfig.transcriber(env: { "STUDIO_VOICE_OPENAI_API_KEY" => "k" }, production: true, qa: true)
  end

  test "production with no voice key names no transcriber, so a take answers 503 not_configured" do
    env = { "OPENAI_API_KEY" => "sk-image" }
    name = HubVoiceConfig.transcriber(env: env, production: true, qa: false)

    assert_equal HubVoiceConfig::NO_KEY, name
    refute_includes Studio::VoiceTranscription::ADAPTERS.keys, name
    with_transcriber(name) do
      error = assert_raises(Studio::VoiceTranscription::NotConfigured) { Studio::VoiceTranscription.transcriber }
      assert_match name, error.message
    end
  end

  test "production with the voice key, a desk, or an explicit mock leaves the engine's choice" do
    assert_nil HubVoiceConfig.transcriber(env: { "STUDIO_VOICE_OPENAI_API_KEY" => "k" }, production: true, qa: false)
    assert_nil HubVoiceConfig.transcriber(env: {}, production: false, qa: false)
    assert_nil HubVoiceConfig.transcriber(env: { "STUDIO_VOICE_TRANSCRIBER" => "mock" }, production: true, qa: false)
    assert_equal HubVoiceConfig::NO_KEY,
                 HubVoiceConfig.transcriber(env: { "STUDIO_VOICE_TRANSCRIBER" => "openai" }, production: true, qa: false)
  end

  private

  def with_transcriber(name)
    was = Studio.voice_transcriber
    Studio.voice_transcriber = name
    yield
  ensure
    Studio.voice_transcriber = was
  end
end
