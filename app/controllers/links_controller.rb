class LinksController < ApplicationController
  # Public link hub — general (non-admin) destinations. Read-only nav page, so
  # it opts out of the engine's authenticate-by-default before_action.
  skip_before_action :require_authentication

  def index; end
end
