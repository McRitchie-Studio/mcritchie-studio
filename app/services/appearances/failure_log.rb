module Appearances
  # FILE A DEGRADED-PATH FAILURE WHERE THE OPERATOR WILL ACTUALLY FIND IT.
  #
  # WHY THIS IS NOT `rescue_and_log`. That is the controller concern's wrapper and it
  # RE-RAISES by design — right for an action that still owes the browser an answer,
  # wrong for every caller here. Appearances::ImageSearch and
  # Appearances::FaceVisibility are both contractually DEGRADE-NEVER-RAISE: an
  # optional enrichment must cost the operator some photographs, never the page. A
  # logger that re-raised would turn a vendor's 401 into a 500 on the one page whose
  # job is to show what we already have.
  #
  # WHY A LOG LINE ALONE WAS NOT ENOUGH. `Rails.logger.warn` is what both of those
  # did before, and the measurable result was that a credential failure and an empty
  # result produced the SAME page — "returned nothing for …". Nobody tails a log to
  # find out why a search looked thin; /admin/error_logs is where they look, and a
  # row there is the only thing that tells a 401 apart from a genuine empty answer.
  #
  # ITS OWN FAILURE IS SWALLOWED, which is not defensive decoration. Every caller is
  # already inside a rescue whose purpose is to keep the page alive, so a raise from
  # the logger would replace the real exception with a useless one and lose the page
  # as well — the same inversion the engine's own `rescue_and_log` guards against
  # when it stamps a target.
  module FailureLog
    # `target` is optional: these services are reachable from a console and a rake
    # task, where there may be no record to file against. A row with no target is
    # still a row — `ErrorLog.capture!` stamps its own slug, so it is still reachable
    # in the admin list rather than invisible.
    def self.file(exception, target: nil)
      log = ErrorLog.capture!(exception)
      if target
        log.target = target
        log.target_name = target.slug if target.respond_to?(:slug)
        log.save!
      end
      log
    rescue StandardError => e
      Rails.logger.warn(
        "[Appearances::FailureLog] could not file #{exception.class}: #{e.class}: #{e.message}"
      )
      nil
    end
  end
end
