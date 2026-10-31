# The Slack outbound ledger (SlackPost): one row per post the hub makes on Slack,
# posted or not, so the noise caps in config/agent_media.yml `limits:` count from
# one shared store. The conductor posts from a `heroku run` dyno and replies post
# from a job dyno, so no in-process counter could see both.
#
# idempotency_key makes a release post exactly-once across a re-run: the row is
# written `sending` BEFORE chat.postMessage, so a crashed or ambiguous attempt is
# never posted again.
class CreateSlackPosts < ActiveRecord::Migration[8.1]
  def change
    create_table :slack_posts do |t|
      t.string :channel_id, null: false
      t.string :thread_ts
      t.string :ts
      t.string :soul_slug
      t.string :kind, null: false
      t.string :status, null: false
      t.string :reason
      t.string :idempotency_key
      t.bigint :agent_message_id
      t.string :release_slug
      t.timestamps
    end
    add_index :slack_posts, %i[channel_id soul_slug created_at]
    add_index :slack_posts, %i[channel_id thread_ts created_at]
    add_index :slack_posts, :idempotency_key, unique: true
    add_index :slack_posts, :release_slug
    add_check_constraint :slack_posts, "kind IN ('post', 'reply', 'release')", name: "slack_posts_kind_known"
    add_check_constraint :slack_posts, "status IN ('sending', 'posted', 'suppressed', 'failed')",
                         name: "slack_posts_status_known"
  end
end
