# /stack — every McRitchie Studio client on one page: the tier they are on, the
# software in their stack (the Studio chest in the corner where we host it),
# and their Google users and Resend mode. Admin-only; records only, no secrets.
class StackController < ApplicationController
  before_action :require_admin

  def index
    @clients = StackClient.ordered.includes(:workspace_account).to_a
    # One read of the census, handed to every row, rather than one per client.
    @records_by_entity = CredentialRecord.includes(:credential_vault).to_a.group_by(&:served_entity)
  end
end
