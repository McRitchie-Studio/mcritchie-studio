# /websites: every live app built on Studio, for a visitor who wants to see real
# work. Public by config/navigation.yml. The list is BuildGallery's, the same
# apps the /build page shows.
class WebsitesController < ApplicationController
  def index
    @examples = BuildGallery.examples
  end
end
