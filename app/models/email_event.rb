# One thing that happened to one broadcast email: the append-only log behind
# the email analytics (task email-event-log-webhooks). Rows come from three
# places, named by `source`:
#
#   resend    Resend's signed webhooks: sent, delivered, delivery_delayed,
#             bounced, complained, opened, clicked
#   pixel     our open pixel (EmailTrackingController#open)
#   redirect  our click redirect (EmailTrackingController#click)
#   page      our unsubscribe page (UnsubscribesController#create)
#   app       our own code: the sender recording the send, /build crediting
#             an app request
#   beacon    a result reported by another app (EmailTrackingController#goal)
#
# `machine` marks an open or click a program made rather than a person (Apple
# Mail's privacy prefetch, a mail scanner following every link): see
# EmailEvents::MachineDetector. Webhook events carry Resend's event id in
# `provider_event_id`, so a redelivered webhook is recorded once.
class EmailEvent < ApplicationRecord
  KINDS = %w[sent delivered delivery_delayed bounced complained opened clicked unsubscribed converted].freeze
  SOURCES = %w[resend pixel redirect page app beacon].freeze

  # What a reader did after clicking, credited to the email (kind "converted",
  # data["goal"]): EmailEvents::Results records these.
  GOALS = %w[signed_in played_match joined_newsletter requested_app].freeze

  belongs_to :broadcast_delivery

  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :occurred_at, presence: true

  scope :human, -> { where(machine: false) }
  scope :of_kind, ->(kind) { where(kind: kind) }
end
