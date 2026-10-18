# frozen_string_literal: true

# THE E2E LANE'S LIVE WEB CHAT. Only in the test env, and only when the Playwright
# server sets E2E_WEB_CHAT_JOBS=1: the CTO web chat's typing pulse and answer
# delivery jobs run in process (async), so e2e/cto_web_chat.spec.js sees "typing…"
# and the answer arrive over the real ActionCable stream (CABLE_ADAPTER=async).
# So does the proposal job, so an owner's `go` opens its task and the result
# streams in.
# The test adapter would only record them. A Discord row's jobs find no bot token
# here and post nothing.
if Rails.env.test? && ENV["E2E_WEB_CHAT_JOBS"] == "1"
  Rails.application.config.to_prepare do
    AgentMessageTypingJob.queue_adapter = :async
    AgentMessageReplyJob.queue_adapter = :async
    AgentProposalJob.queue_adapter = :async
  end
end
