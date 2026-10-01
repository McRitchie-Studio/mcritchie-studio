class ScheduleController < ApplicationController
  # Public: this is the page the site's "Schedule a call" links land on.
  skip_before_action :require_authentication

  # The studio's Google Calendar appointment schedule. It checks every one of
  # the operator's calendars for conflicts, which is why bookings go through it.
  BOOKING_URL = "https://calendar.google.com/calendar/appointments/schedules/" \
                "AcZssZ3_1hQYaxXWJCG8T-AAuv6YHQN9w3aRBnp-rtQc10YqH6k6Yy6FjUTtZLnwoT27Sr30YcOuZI1K".freeze

  def index
  end
end
