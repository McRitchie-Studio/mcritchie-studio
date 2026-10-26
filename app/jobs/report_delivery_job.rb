# ReportDestinations.deliver for an async caller
# (docs/agents/system/report-destinations.md): enqueue it and move on.
#
#   ReportDeliveryJob.perform_later("daily_app_report", content: "…", embeds: [],
#                                   idempotency_key: "daily_app_report:2026-10-15")
#
# A Discord failure (AgentMessages::DiscordBot::Error, a rate limit included) is
# retried with a polynomial back-off, five tries in all; every retry carries the
# same idempotency_key, so the report still posts at most once. A not-configured
# or disabled destination is recorded and NOT retried: that waits on Alex McRitchie.
class ReportDeliveryJob < ApplicationJob
  queue_as :default
  retry_on AgentMessages::DiscordBot::Error, wait: :polynomially_longer, attempts: 5

  def perform(report_key, content:, idempotency_key:, embeds: [])
    ReportDestinations.deliver!(report_key, content: content, embeds: embeds, idempotency_key: idempotency_key)
  end
end
