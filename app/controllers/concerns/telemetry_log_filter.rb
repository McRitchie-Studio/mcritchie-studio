# frozen_string_literal: true

# Keeps agent-telemetry BODIES out of the request log.
#
# The live-capture hook POSTs one AgentAction per agent tool call, and the
# PreToolUse hook POSTs the assistant's preamble to turn_open. Rails logged each
# body in full on the `Parameters:` line, TWICE (once at the top level and once
# under the params-wrapper key, e.g. "agent_action"), so an hour of agent work
# put megabytes of prompts, command output and diffs through the web dyno's
# logger. Measured 2026-10-06 over 1,066 web log lines: 25 agent_actions#create
# requests logged 167 KB of params and 25 turn_open requests 50 KB, against
# under 2 KB for 3 agent_activities#create. hub-web-memory-stays-under.
#
# The filter is NARROW on purpose. A global `:input`/`:output` entry in
# config/initializers/filter_parameter_logging.rb would also mask every other
# controller's `input` param and, through filter_attributes, every model's
# `input`/`output` column in an inspect. Here the extra keys apply only to the
# controllers that include this concern; the global list still applies too.
#
# The VALUES still reach the action untouched: AgentAction.capture stores the
# hook-truncated input/output exactly as before. Only the log line changes.
module TelemetryLogFilter
  extend ActiveSupport::Concern

  # Anchored, so `tokens_in`/`input_tokens` and the like stay readable. A
  # regexp without "\." is tested against the bare key at every depth, so the
  # wrapped copy ("agent_action" => { "input" => ... }) is masked as well.
  BODY_KEYS = /\A(?:input|output|preamble|prompt)\z/

  private

  # Instrumentation#process_action reads request.filtered_parameters to build
  # the `start_processing` payload the log subscriber prints. This override runs
  # before it (a subclass method sits above the Instrumentation module), so the
  # per-request filter is in place when that first, memoized read happens.
  def process_action(*)
    request.set_header(
      "action_dispatch.parameter_filter",
      Array(request.get_header("action_dispatch.parameter_filter")) + [BODY_KEYS]
    )
    super
  end
end
