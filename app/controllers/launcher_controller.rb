class LauncherController < ApplicationController
  # Session entry launcher — a terminal-styled chooser for HOW you enter a
  # session: Session agent (build), Avi (QA review), or Alex (learning
  # heartbeat). Read-only meta surface, so it opts out of the engine's
  # authenticate-by-default before_action, like /links and /toast_test.
  skip_before_action :require_authentication

  def index; end

  # Placeholder for the Alex learning / distillation heartbeat. The real view is
  # a separate task (T2). The Alex avenue points here so the route name
  # (alex_heartbeat_path) stays stable; T2 repoints this action at its own
  # controller/view without touching the launcher.
  # TODO(T2 learning-heartbeat): replace this placeholder with the heartbeat view.
  def heartbeat; end
end
