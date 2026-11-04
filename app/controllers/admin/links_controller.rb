module Admin
  # Admin link hub — gathers every admin/operator destination. Admin-gated; the
  # nav only links here when admin?. There is no On-chain section: its only link
  # was the signing console, deleted 2026-09-04 (/tasks/retire-signing-console).
  #
  # The Basement (/admin/basement) is the page of links kept off the sidebar. The
  # hub stays the whole index: the sidebar's admin sections, then the Basement's.
  class LinksController < ApplicationController
    before_action :require_admin

    def index; end

    def basement; end
  end
end
