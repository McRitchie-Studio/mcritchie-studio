# Rack::Attack keys a counter by Time.now / period. A throttle test that crosses a
# period boundary on the wall clock splits its count in two, so it freezes the
# clock on a period's first second instead.
module ThrottleClock
  # Freezes Time.now on the next instant at which every given period begins.
  def start_throttle_period(*periods)
    span = periods.map(&:to_i).reduce(:lcm)
    travel_to Time.at((Time.now.to_i / span + 1) * span)
  end
end
