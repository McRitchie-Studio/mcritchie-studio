module Admin
  # The Basement (/admin/basement) is the one page of links: what the sidebar does not
  # carry. There is no On-chain section: its only link was the signing console, deleted
  # 2026-09-04 (/tasks/retire-signing-console).
  #
  # /admin/links was the admin link hub and now only sends a bookmark to the Basement
  # (Alex McRitchie, 2026-11-04: "consolidate to a single page"). The redirect is an
  # action and not a route's, so require_admin answers first and a non-admin is refused
  # as before, without learning the page exists.
  class LinksController < ApplicationController
    before_action :require_admin

    def index
      redirect_to admin_basement_path
    end

    def basement; end
  end
end
