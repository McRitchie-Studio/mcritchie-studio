# Runs Content::PostVideoToX off the request. NEVER RETRIED: ApplicationJob
# retries any StandardError three times, and a retried post is a second public
# post. The service rescues everything itself and records the outcome on the
# card; this discard is the belt for anything that still escapes.
class ContentPostVideoToXJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(slug)
    content = Content.find_by(slug: slug) or return
    Content::PostVideoToX.new(content).call
  end
end
