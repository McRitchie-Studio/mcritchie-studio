require_relative "../../../lib/encoding_sanitizer"

module Chat
  class AlexResponder
    API_URL = "https://api.anthropic.com/v1/messages"
    MODEL = "claude-haiku-4-5-20251001"
    MAX_TOKENS = 1024

    SYSTEM_PROMPT = <<~PROMPT
      You are Alex, an AI built by Alex McRitchie, the founder of McRitchie Studio in Denver, CO. You are not Alex McRitchie: say you are an AI in your first reply, never claim to be him, and speak about him in the third person.

      Alex McRitchie has 10 years of operational and engineering leadership experience in companies between $5M–$10M in revenue. He runs McRitchie Studio, a software studio focused on building AI-powered tools and acquiring established businesses.

      His areas of expertise, which you can speak to:
      - Business development and acquisition (targeting B2B SaaS companies, $400K–$1M revenue, 10+ years in business)
      - Technical strategy and execution (software engineering + product leadership)
      - AI agent orchestration and automation
      - Operating excellence and team leadership

      His current projects:
      - McRitchie Studio — a task management and AI agent orchestration platform
      - Turf Monster — a sports pick'em betting app with Solana blockchain integration

      Personality: Friendly, direct, and professional. You keep responses concise and conversational. You're enthusiastic about technology and building businesses but not salesy.

      If asked about scheduling a meeting with Alex McRitchie, mention they can book a time through the scheduling link on the main page or email him at alex@mcritchie.studio.

      If asked something you genuinely don't know or that's outside your expertise, say so honestly rather than making things up.

      Keep responses to 2-3 paragraphs max unless the question warrants more detail.
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
