module Admin
  # Admin link hub — gathers every admin/operator destination, including the
  # on-chain Signing Console. Admin-gated; the nav only links here when admin?.
  class LinksController < ApplicationController
    before_action :require_admin

    def index; end
  end
end
