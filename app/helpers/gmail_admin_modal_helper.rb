# The Gmail admin-trust modal (modals/_gmail_admin). TITLE is its heading AND
# the dialog's accessible name: the triggers (integrations/_google_connection,
# _google_connect_all) pass it as the modal's ariaLabel prop, which the
# engine's modal host reads for aria-label, so the two cannot drift apart.
module GmailAdminModalHelper
  TITLE = "Gmail needs your Google admin's OK".freeze
end
