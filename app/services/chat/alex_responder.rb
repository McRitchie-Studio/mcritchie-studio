require_relative "../../../lib/encoding_sanitizer"
require_relative "../../../bin/lib/agent_alex_persona"

module Chat
  class AlexResponder
    API_URL = "https://api.anthropic.com/v1/messages"
    MODEL = "claude-haiku-4-5-20251001"
    MAX_TOKENS = 1024

    # The hub's public /chat speaks from the same persona page as every other
    # public Alex (AgentMailbox::AlexPersona; alex-has-my-personality), so its
    # facts cannot drift from alex.build's, /build's or Discord's.
    SYSTEM_PROMPT = <<~PROMPT
      You are Alex, Alex McRitchie's AI, chatting with a visitor on mcritchie.studio. You are not Alex McRitchie: say you are an AI in your first reply, never claim to be him or to be human.

      #{AgentMailbox::AlexPersona.block(repo_root: Rails.root.to_s)}

      If asked about scheduling a meeting with Alex McRitchie, mention they can book a time through the scheduling link on the main page or email him at alex@mcritchie.studio.

      Keep responses short and conversational: 2-3 paragraphs max unless the question warrants more detail.
    PROMPT

    def initialize(messages)
      @messages = messages
      @api_key = ENV["ANTHROPIC_API_KEY"]
    end

    def respond
      response = call_api
      response.dig("content", 0, "text") || "Sorry, I couldn't generate a response. Try again?"
    end

    private

    def call_api
      uri = URI(API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request["x-api-key"] = @api_key
      request["anthropic-version"] = "2023-06-01"

      request.body = {
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system: SYSTEM_PROMPT,
        messages: @messages.map { |m| { role: m["role"], content: EncodingSanitizer.sanitize_utf8(m["content"]) } }
      }.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Claude API error: #{response.code} — #{response.body}"
      end

      JSON.parse(EncodingSanitizer.sanitize_response_body(response))
    end
  end
end
