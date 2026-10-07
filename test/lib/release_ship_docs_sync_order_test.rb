# frozen_string_literal: true

# The ship restores the primaries BEFORE it publishes the agent docs, so the
# fallback tree in bin/release.rb#sync_agent_docs, when it is taken, is as current
# as the restore could make it. The branches the sync itself takes are driven in
# test/lib/release_cli_post_deploy_test.rb.
#
#   ruby -Itest test/lib/release_ship_docs_sync_order_test.rb

require "minitest/autorun"

class ReleaseShipDocsSyncOrderTest < Minitest::Test
  RELEASE = File.expand_path("../../bin/release.rb", __dir__)

  def test_ship_runs_sync_agent_docs_after_restore_primaries
    src = File.read(RELEASE)
    restore_at = src.index("restore_primaries(app_groups)")
    sync_at = src.index("sync_agent_docs\n")
    assert restore_at && sync_at, "ship must call both restore_primaries and sync_agent_docs"
    assert_operator restore_at, :<, sync_at, "the docs sync runs after the primaries are restored"
  end
end
