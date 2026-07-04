class AddStageTimestampsToReleases < ActiveRecord::Migration[8.1]
  # The release stage timeline: each column is a time-and-boolean stage marker
  # (stamped = the stage started/landed; blank = not yet). Together with the
  # existing assembled_at / confirmed_at / shipped_at they form the ordered
  # Release::STAGES sequence the /deployments pizza-tracker reads. Stamps are
  # first-write-wins (see Release#stamp_stage!) so replays never rewrite history.
  def up
    add_column :releases, :testing_started_at, :datetime
    add_column :releases, :assembling_started_at, :datetime
    add_column :releases, :qa_deploy_started_at, :datetime
    add_column :releases, :qa_deployed_at, :datetime
    add_column :releases, :confirming_started_at, :datetime
    add_column :releases, :prod_deploy_started_at, :datetime

    backfill_from_history
  end

  def down
    remove_column :releases, :testing_started_at
    remove_column :releases, :assembling_started_at
    remove_column :releases, :qa_deploy_started_at
    remove_column :releases, :qa_deployed_at
    remove_column :releases, :confirming_started_at
    remove_column :releases, :prod_deploy_started_at
  end

  private

  # Existing releases predate the stamps, so the tracker would regress them to
  # "nothing started". Recover each stamp from the durable history that already
  # encodes it: the release_events audit trail where one exists, else the
  # release's own lifecycle columns (created_at opens the sweep, so it is the
  # honest assembling start; a QA URL or an assembled state proves QA landed).
  def backfill_from_history
    say_with_time "backfilling release stage stamps from events + lifecycle columns" do
      execute <<~SQL
        UPDATE releases SET
          testing_started_at = (
            SELECT MIN(occurred_at) FROM release_events
            WHERE release_events.release_slug = releases.slug
              AND step = 'review_tests' AND status = 'started'
          ),
          assembling_started_at = releases.created_at,
          qa_deploy_started_at = (
            SELECT MIN(occurred_at) FROM release_events
            WHERE release_events.release_slug = releases.slug
              AND step = 'deploy_qa' AND status = 'started'
          ),
          qa_deployed_at = COALESCE(
            (SELECT MIN(occurred_at) FROM release_events
             WHERE release_events.release_slug = releases.slug
               AND step IN ('deploy_qa', 'qa_smoke') AND status = 'completed'),
            CASE WHEN releases.qa_url IS NOT NULL OR releases.state IN ('assembled', 'shipped')
                 THEN releases.assembled_at END
          ),
          confirming_started_at = (
            SELECT MIN(occurred_at) FROM release_events
            WHERE release_events.release_slug = releases.slug
              AND step IN ('ship_gate', 'ship_authorized') AND status = 'started'
          ),
          prod_deploy_started_at = COALESCE(
            (SELECT MIN(occurred_at) FROM release_events
             WHERE release_events.release_slug = releases.slug
               AND step = 'deploy_prod' AND status = 'started'),
            CASE WHEN releases.state = 'shipped' THEN releases.confirmed_at END
          )
      SQL
    end
  end
end
