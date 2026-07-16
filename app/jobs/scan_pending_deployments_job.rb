# Recurring poll (config/recurring.yml, production only) that surfaces prod-deploy
# runs waiting on the operator-approval gate. GitHub will not deliver
# `deployment_review` to our PAT-created repo webhook, so this READS the signal via
# Github::PendingDeploymentScanner and replays it through the ingest job. Thin by
# design — the scanner owns the logic and swallows its own errors.
class ScanPendingDeploymentsJob < ApplicationJob
  def perform
    Github::PendingDeploymentScanner.scan!
  end
end
