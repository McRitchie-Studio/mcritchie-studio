module Admin
  # Admin link hub — gathers every admin/operator destination. Admin-gated; the
  # nav only links here when admin?. There is no On-chain section: its only link
  # was the signing console, deleted 2026-09-04 (/tasks/retire-signing-console).
  class LinksController < ApplicationController
    before_action :require_admin

    def index; end
  end
end
