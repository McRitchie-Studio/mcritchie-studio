# Which Discord bot posted a report (docs/agents/system/report-destinations.md,
# "Which bot posts"): a CTO report posts as its CTO soul's own bot when
# DISCORD_BOT_TOKEN_<SOUL> is set, else as the shared agents' bot.
#
#   posted_via           "soul_bot" or "shared_bot" once posted; nil before
#   soul_bot_refused_at  when the soul's bot answered 401/403 for this delivery.
#                        A retry of the same idempotency key sees it and goes
#                        straight to the shared bot, so a report that fell back
#                        once can never be posted again by the soul's bot.
#
# Existing rows keep nil: every one of them was posted by the shared bot, and the
# page reads nil as "not recorded" rather than guessing.
class AddPostedViaToReportDeliveries < ActiveRecord::Migration[8.1]
  def change
    add_column :report_deliveries, :posted_via, :string
    add_column :report_deliveries, :soul_bot_refused_at, :datetime
  end
end
