# The numbers behind /contacts (task contacts-admin-page): where one mailing
# list stands while a verification run or a batched send works through it.
#
# Every count comes from three grouped queries over the list, whatever its
# size, so the page can poll them every few seconds:
#
#   1. one aggregate row: total, subscribed, verified-valid, undeliverable,
#      not yet verified, emailed at least once, and the last verification time
#   2. contacts per verification_status (NULL is "unverified")
#   3. unsubscribed contacts per reason
#
# `list` is a tag ("cyvasse-legacy") or ALL for every contact.
module Contacts
  class Dashboard
    ALL = "all".freeze
    DEFAULT_LIST = "cyvasse-legacy".freeze
    UNVERIFIED = "unverified".freeze

    # The verification breakdown's rows, in the order the page draws them.
    STATUS_ROWS = (Contact::VERIFICATION_STATUSES + [ UNVERIFIED ]).freeze

    Stats = Struct.new(:total, :subscribed, :valid, :mailable, :undeliverable, :unverified, :emailed,
                       :last_verified_at, :by_status, :unsubscribed, keyword_init: true) do
      def verified = total - unverified

      # How far the verification has come, 0-100.
      def verified_pct
        total.zero? ? 0.0 : (100.0 * verified / total)
      end

      def status_pct(status)
        total.zero? ? 0.0 : (100.0 * by_status.fetch(status, 0) / total)
      end
    end

    # The contacts on `list`. A tag that no contact carries is an empty list.
    def self.scope_for(list)
      list.to_s == ALL ? Contact.all : Contact.where("contacts.tags @> ARRAY[?]::varchar[]", list.to_s)
    end

    # Every tag with its contact count, most contacts first: the list picker.
    def self.lists
      Contact.from("contacts, unnest(contacts.tags) AS tag")
             .group("tag").order(Arel.sql("count(*) DESC, tag")).count.to_a
    end

    attr_reader :list

    def initialize(list: DEFAULT_LIST)
      @list = list.presence || DEFAULT_LIST
    end

    def scope = self.class.scope_for(list)

    def stats
      Stats.new(**totals, by_status: by_status, unsubscribed: unsubscribed)
    end

    private

    def totals
      undeliverable = Contact.sanitize_sql_array([ "verification_status IN (?)", Contact::UNDELIVERABLE_STATUSES ])
      emailed = "EXISTS (SELECT 1 FROM broadcast_deliveries bd WHERE bd.contact_id = contacts.id AND bd.sent_at IS NOT NULL)"
      row = scope.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE subscribed)"),
        Arel.sql("COUNT(*) FILTER (WHERE verification_status = 'valid')"),
        Arel.sql("COUNT(*) FILTER (WHERE verification_status = 'valid' AND subscribed)"),
        Arel.sql("COUNT(*) FILTER (WHERE #{undeliverable})"),
        Arel.sql("COUNT(*) FILTER (WHERE verified_at IS NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE #{emailed})"),
        Arel.sql("MAX(verified_at)")
      )
      keys = %i[total subscribed valid mailable undeliverable unverified emailed last_verified_at]
      keys.zip(row).to_h
    end

    # A contact with no verified_at counts as unverified whatever its status says.
    def by_status
      counts = scope.group(Arel.sql("CASE WHEN verified_at IS NULL THEN '#{UNVERIFIED}' ELSE verification_status END")).count
      STATUS_ROWS.index_with { |status| counts.fetch(status, 0) }
    end

    # Off-list contacts per reason. A reason left blank predates reasons, and
    # was a reader's own request.
    def unsubscribed
      counts = scope.where(subscribed: false).group(Arel.sql("COALESCE(unsubscribe_reason, 'requested')")).count
      Contact::UNSUBSCRIBE_REASONS.index_with { |reason| counts.fetch(reason, 0) }
    end
  end
end
