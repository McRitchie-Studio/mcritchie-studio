class AddAgentClaimToContents < ActiveRecord::Migration[8.1]
  def change
    # The agent lease. A soul claims a Content, writes its script/captions with
    # its own inference, and releases — so two sessions draining the same queue
    # cannot both script the same game and produce two different takes.
    #
    # `claimed_by` is the SOUL (turf-monster, mason) and is what a human reads
    # off the board. `claim_session` is the SESSION and is what a release is
    # checked against, because two runs of the same soul are different holders.
    add_column :contents, :claimed_by, :string
    add_column :contents, :claim_session, :string
    add_column :contents, :claimed_at, :datetime

    # The claim pop orders by stage then board position, and filters on an
    # expired-or-absent lease. Indexed on the pair it actually scans.
    add_index :contents, [:stage, :claimed_at]
  end
end
