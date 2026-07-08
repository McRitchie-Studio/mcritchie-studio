class AddTestedAtToReleases < ActiveRecord::Migration[8.1]
  # The explicit completion of the release's Testing stage — paired with
  # testing_started_at, it bookends the "review tests" run in the Release::STAGES
  # timeline (testing → tested → assembling). First-write-wins like the other
  # stage stamps (see Release#stamp_stage!). Legacy releases predate any
  # review_tests completion event, so there is nothing to backfill from — they
  # stay NULL and the /deployments "Tested" cell reads "—" for them.
  def change
    add_column :releases, :tested_at, :datetime
  end
end
