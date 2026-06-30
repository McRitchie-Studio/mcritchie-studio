class LauncherController < ApplicationController
  # Session entry launcher — a terminal-styled chooser for HOW you enter a
  # session: Session agent (build), Avi (QA review), or Alex (learning
  # heartbeat). Read-only meta surface, so it opts out of the engine's
  # authenticate-by-default before_action, like /links and /toast_test.
  skip_before_action :require_authentication

  def index; end
end
