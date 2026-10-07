# Runs Tiktok::DraftClip#run off the request: upload a clip's primary version
# into the operator's TikTok drafts, then poll TikTok's status.
#
# NEVER RETRIED: ApplicationJob retries any StandardError three times, and a
# retried upload is a second draft on the phone. The service records every
# failure on the TiktokDraft row itself; this discard is the belt for anything
# that still escapes, and a retry is the operator's click, as a new attempt.
class TiktokDraftJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(draft_id)
    draft = TiktokDraft.find_by(id: draft_id) or return
    Tiktok::DraftClip.new.run(draft)
  end
end
