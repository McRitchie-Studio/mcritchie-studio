class ScheduleController < ApplicationController
  # Public: this is the page the site's "Schedule a call" links land on.
  skip_before_action :require_authentication

  # The view renders the engine's booking frame (`studio_booking_frame`) for the
  # schedule in Studio.booking_url (config/initializers/studio.rb). This app
  # keeps the route so the page keeps its own title and copy.

  def index
  end
end
