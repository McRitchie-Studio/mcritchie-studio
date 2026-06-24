# The /deployments board's live feed. Clients on the board subscribe; the server
# pushes a re-rendered task card (DeploymentsBroadcaster) whenever a task's stage
# changes or an agent starts a stage's work (an intent), so the board updates
# without a reload. A single shared stream — the board is a small, fully-visible
# operator surface, so there's no per-user scoping to do.
class DeploymentsChannel < ApplicationCable::Channel
  STREAM = "deployments"

  def subscribed
    stream_from STREAM
  end
end
