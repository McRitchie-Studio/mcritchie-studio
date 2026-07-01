require_relative "../../../lib/encoding_sanitizer"

# Avi's LLM shirt-sizer. Given a freshly DESIGNED task, Avi (the Product Owner)
# reads its title, acceptance criteria, kind/shape, and agent_context and returns
# ONE t-shirt size from Task::SIZES — the `po_size` forecast leg of the sizing
# trio (po = Avi's estimate at creation).
#
# This is the LLM ADAPTER for the feature. It mirrors the house Anthropic pattern
# (Chat::AlexResponder, News::ReviewAgent, Content::MetadataAgent): a direct
# Net::HTTP call to the Messages API, same MODEL, keyed off ENV["ANTHROPIC_API_KEY"].
# Kept as a thin service (not baked into the job) so the LLM seam is trivially
# stubbable in tests — the job stubs #call, the sizer's own tests stub #call_api.
#
# Backend discipline — graceful degradation is the whole point here:
#   * NO api key   -> returns nil (benign config state: test/CI/seed run without a
#                     key must NOT raise or spam ErrorLog; sizing just stays blank).
#   * unparseable  -> returns nil (never fabricate a size the model didn't pick).
#   * runtime error (HTTP failure, non-2xx, timeout) -> RAISES, so the calling
#                     AviSizingJob logs it to ErrorLog. The task NEVER blocks on us.
module Avi
  class Sizer
    API_URL = "https://api.anthropic.com/v1/messages"
    MODEL = "claude-haiku-4-5-20251001"
    MAX_TOKENS = 16

    # The valid sizes are the model's own vocabulary — reuse it so a future size
    # (e.g. "xxl") flows through without editing the sizer.
    SIZES = Task::SIZES

    SYSTEM_PROMPT = <<~PROMPT
      You are Avi, Product Owner at McRitchie Studio. You t-shirt-size engineering
      tasks so the team can forecast effort. You size the WORK, not the writeup.

      Sizing rubric (total build effort for one agent, end to end):
      - small:  a quick, contained change — one file/area, little risk, minutes to an hour.
      - medium: a normal feature — a few files, a migration or a job or a service, some tests.
      - large:  a heavy, multi-stage build — many files, cross-cutting, careful testing.
      - xl:     an epic — new subsystem, on-chain/vertical work, or broad blast radius.

      Respond with EXACTLY ONE lowercase word and nothing else: small, medium, large, or xl.
    PROMPT

    def initialize(task)
      @task = task
      @api_key = ENV["ANTHROPIC_API_KEY"]
    end

    # => "small" | "medium" | "large" | "xl" | nil
    def call
      # A missing key is a benign configuration state (keyless test/CI/seed runs),
      # not an error: degrade to "unsized" rather than raise into ErrorLog.
      if @api_key.blank?
        Rails.logger.info("[Avi::Sizer] ANTHROPIC_API_KEY unset — leaving #{@task.slug} unsized")
        return nil
      end

      parse_size(response_text)
    end

    private

    # Map the model's reply to a valid size, else nil. Defensive: the model is
    # asked for a bare word, but we scan for the first size token anywhere so a
    # stray "Size: medium." or a leading newline still maps cleanly. Never
    # fabricates — an answer with no size word returns nil.
    def parse_size(text)
      match = text.to_s.downcase.scan(/\b(small|medium|large|xl)\b/).flatten.first
      SIZES.include?(match) ? match : nil
    end

    def response_text
      response = call_api
      response.dig("content", 0, "text").to_s
    end

    def user_prompt
      d = @task.devops
      lines = []
      lines << "Title: #{@task.title}"
      lines << "Kind: #{@task.devops_kind}"
      lines << "Shape: #{@task.devops_shape}" if @task.devops_shape.present?
      acceptance = @task.devops_acceptance
      if acceptance.any?
        lines << "Acceptance criteria:"
        acceptance.each { |bullet| lines << "- #{bullet}" }
      end
      context = @task.devops_agent_context
      lines << "Notes: #{context}" if context.present?
      lines << "Description: #{@task.description}" if @task.description.present? && d.blank?
      lines.join("\n")
    end

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
        messages: [{ role: "user", content: EncodingSanitizer.sanitize_utf8(user_prompt) }]
      }.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Claude API error: #{response.code} — #{response.body}"
      end

      JSON.parse(EncodingSanitizer.sanitize_response_body(response))
    end
  end
end
