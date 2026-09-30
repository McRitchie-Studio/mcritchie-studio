# The contacts table on /contacts (task contacts-admin-page): one page of the
# list, searched and filtered, with each contact's send history rolled up.
#
# Filters (all optional):
#   q          part of an email address
#   list       a tag, or Contacts::Dashboard::ALL
#   subscribed "yes" | "no"
#   status     a verification status, "unverified", or "verified" (any result)
#   emailed    "yes" | "no" — sent at least one broadcast
#
# A page is PER_PAGE contacts by limit and offset. Filtering to verified
# contacts orders by the newest verification first; otherwise newest contact
# first. The per-contact rollups are two grouped queries over the page's ids.
module Contacts
  class Directory
    PER_PAGE = 50
    STATUS_FILTERS = (%w[verified] + Dashboard::STATUS_ROWS).freeze

    Row = Struct.new(:contact, :sent, :last_opened_at, :last_clicked_at, keyword_init: true)

    attr_reader :params, :page

    def initialize(params = {})
      @params = params.to_h.symbolize_keys.slice(:q, :list, :subscribed, :status, :emailed)
      @params[:list] = @params[:list].presence || Dashboard::DEFAULT_LIST
      @page = [ params.to_h.symbolize_keys[:page].to_i, 1 ].max
    end

    def relation
      scope = Dashboard.scope_for(params[:list])
      if (q = params[:q].to_s.strip.downcase).present?
        scope = scope.where("contacts.email LIKE ?", "%#{Contact.sanitize_sql_like(q)}%")
      end
      scope = scope.where(subscribed: params[:subscribed] == "yes") if %w[yes no].include?(params[:subscribed])
      scope = filter_status(scope)
      scope = filter_emailed(scope)
      scope
    end

    def total = @total ||= relation.count

    def pages = [ (total.to_f / PER_PAGE).ceil, 1 ].max

    def verified_order?
      params[:status].present? && params[:status] != Dashboard::UNVERIFIED && STATUS_FILTERS.include?(params[:status])
    end

    def rows
      @rows ||= begin
        order = verified_order? ? Arel.sql("contacts.verified_at DESC NULLS LAST, contacts.id DESC") : { id: :desc }
        contacts = relation.order(order).limit(PER_PAGE).offset((page - 1) * PER_PAGE).to_a
        sent = sent_counts(contacts.map(&:id))
        engagement = engagement(contacts.map(&:id))
        contacts.map do |c|
          opened, clicked = engagement[c.id]
          Row.new(contact: c, sent: sent.fetch(c.id, 0), last_opened_at: opened, last_clicked_at: clicked)
        end
      end
    end

    private

    def filter_status(scope)
      case params[:status]
      when "verified" then scope.verified
      when Dashboard::UNVERIFIED then scope.unverified
      when *Contact::VERIFICATION_STATUSES then scope.verified.where(verification_status: params[:status])
      else scope
      end
    end

    def filter_emailed(scope)
      sent = BroadcastDelivery.where.not(sent_at: nil).select(:contact_id)
      case params[:emailed]
      when "yes" then scope.where(id: sent)
      when "no" then scope.where.not(id: sent)
      else scope
      end
    end

    def sent_counts(ids)
      return {} if ids.empty?

      BroadcastDelivery.where(contact_id: ids).where.not(sent_at: nil).group(:contact_id).count
    end

    # The latest open (our pixel) and click (our redirect) per contact, from the
    # event log: a delivery row keeps only the first of each.
    def engagement(ids)
      return {} if ids.empty?

      EmailEvent.joins(:broadcast_delivery).where(broadcast_deliveries: { contact_id: ids })
                .group("broadcast_deliveries.contact_id")
                .pluck(Arel.sql("broadcast_deliveries.contact_id"),
                       Arel.sql("MAX(email_events.occurred_at) FILTER (WHERE email_events.kind = 'opened' AND email_events.source = 'pixel')"),
                       Arel.sql("MAX(email_events.occurred_at) FILTER (WHERE email_events.kind = 'clicked' AND email_events.source = 'redirect')"))
                .to_h { |id, opened, clicked| [ id, [ opened, clicked ] ] }
    end
  end
end
