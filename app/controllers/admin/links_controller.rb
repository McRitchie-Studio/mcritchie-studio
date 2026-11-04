module Admin
  # Admin link hub — gathers the admin/operator destinations. Admin-gated; the
  # nav only links here when admin?. There is no On-chain section: its only link
  # was the signing console, deleted 2026-09-04 (/tasks/retire-signing-console).
  #
  # The Basement (/admin/basement) is the page of links kept off the sidebar. The
  # hub lists the sidebar's admin sections, then the Basement's; a page placed in no
  # section (/dashboard, /applications, /agents, /tasks) is not on it.
  class LinksController < ApplicationController
    before_action :require_admin

    def index; end

    def basement; end
  end
end
