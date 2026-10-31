# The outbound ledger (SlackPost, table slack_posts) becomes medium-neutral:
# Microsoft Teams posts and replies are written to it beside Slack's, so the
# noise caps (Media::Limits, config/agent_media.yml `limits:`) count both from
# one store. Every existing row is Slack's (the default). The table keeps its
# name in this card (teams-medium-loop); a rename is its own change.
class AddMediumToSlackPosts < ActiveRecord::Migration[8.1]
  def change
    add_column :slack_posts, :medium, :string, null: false, default: "slack"
    add_check_constraint :slack_posts, "medium IN ('slack', 'teams')", name: "slack_posts_medium_known"
  end
end
