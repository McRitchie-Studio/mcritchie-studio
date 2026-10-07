# frozen_string_literal: true

# Logs the active malloc once per boot in production, so the allocator change
# planned in docs/agents/system/web-memory-allocator.md is verified from
# `heroku logs`, not assumed. Puma preloads the app, so the master logs once and
# its forked workers inherit the same allocator.
Rails.application.config.after_initialize do
  AllocatorReport.log_boot(Rails.logger) if Rails.env.production?
end
