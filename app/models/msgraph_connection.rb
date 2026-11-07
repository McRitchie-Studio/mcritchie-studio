# A Microsoft 365 tenant the hub reads through Microsoft Graph, app-only: the
# `admin_grant` connection method of config/integrations.yml, on the Microsoft
# 365 card of /integrations and the /admin/msgraph page. A tenant administrator
# approves the hub's multi-tenant Entra app once (the admin-consent endpoint);
# the hub then asks for tokens as itself (the client-credentials flow), so no
# person's sign-in, and no refresh token, is ever stored. The access token is
# cached in process memory only (Msgraph::OAuthClient.access_token).
#
# One row per tenant. The tenant id is the one secret-ish fact a row holds: it
# is encrypted at rest, filtered from logs and inspect, and never rendered.
# `tenant_key` (a keyed digest of the id) is what makes the row unique, so a
# tenant consented twice keeps one row. The page names a tenant only by its
# `display_name` (the organization's name as Graph answers it, else LABEL).
#
# Read only: the app registration asks for application permissions that read
# and nothing else (Msgraph::OAuthClient::PERMISSIONS).
#
# GODADDY-FEDERATED TENANTS. A tenant bought as "Microsoft 365 from GoDaddy" is
# federated to GoDaddy's reseller identity, and admin consent to a third-party
# app is blocked there until the tenant is defederated from GoDaddy. Check the
# tenant in the Microsoft 365 admin center before pressing Connect; a refused
# consent from such a tenant is that block, not a bug here.
#
# THE ROW DEPENDS ON THE APP'S ENCRYPTION KEYS, as FathomConnection's does:
# without them the consent refuses before it asks Microsoft for anything; with
# them lost or changed, a stored row is unreadable (#readable? is false), counts
# as not connected, and consenting again replaces it.
class MsgraphConnection < ApplicationRecord
  ENCRYPTION_ENV = Fact::ENCRYPTION_ENV
  # The tenant's name when Graph does not say it.
  LABEL = "Microsoft 365 tenant".freeze
  # A tenant id as the consent callback carries it: a GUID.
  TENANT_ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  encrypts :tenant_id
  self.filter_attributes += %i[tenant_id tenant_key]

  validates :tenant_id, presence: true, format: { with: TENANT_ID, allow_blank: true }
  validates :tenant_key, presence: true, uniqueness: true
  validates :display_name, :connected_at, presence: true

  class << self
    def encryption_ready? = Fact.encryption_ready?

    # The keyed digest that keeps one row per tenant without storing the id in the clear.
    def tenant_key_for(tenant_id)
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "msgraph-tenant:#{tenant_id.to_s.strip.downcase}")
    end

    def newest_first = order(connected_at: :desc, id: :desc)

    # Every tenant whose row this server can read, newest first.
    def readable = newest_first.select(&:readable?)

    # Stores the tenant an admin consent connected. Consenting the same tenant
    # again updates its row. Raises RecordInvalid when the id is not a GUID;
    # the message names the field, never a value.
    def store!(tenant_id:, display_name:, by:, now: Time.current)
      tenant_id = tenant_id.to_s.strip.downcase
      transaction(requires_new: true) do
        connection = find_or_initialize_by(tenant_key: tenant_key_for(tenant_id))
        # A row whose id can no longer be read is replaced, not updated.
        unless connection.new_record? || connection.readable?
          where(id: connection.id).delete_all
          connection = new(tenant_key: connection.tenant_key)
        end
        connection.assign_attributes(tenant_id:, display_name: display_name.to_s.strip.presence || LABEL, connected_by: by, connected_at: now)
        connection.save!
        connection
      end
    end
  end

  # Can the stored tenant id be decrypted with this app's keys?
  def readable?
    tenant_id
    true
  rescue ActiveRecord::Encryption::Errors::Base
    false
  end
end
