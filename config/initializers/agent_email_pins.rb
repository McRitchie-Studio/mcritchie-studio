# Owner trust on email rests on the pinned DKIM selector in config/agent_routes.yml
# (`email.pinned_dkim`; AgentMessages::EmailTrust, "PINNED SELECTORS"). Without a
# pin for the team address's domain, any DKIM that passes for mcritchie.studio,
# a Resend send included, would be trusted as Alex. So production refuses to boot
# when the pin is missing, empty or misspelled; other environments boot as before.
# Carl's review of ctos-answer-team-email, hardening note 3.
Rails.application.config.after_initialize do
  AgentMessages::EmailRoutes.verify_pins!
end
