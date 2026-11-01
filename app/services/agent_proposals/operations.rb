module AgentProposals
  # The named operations a domain agent's `operate` capabilities name
  # (config/agent_domains.yml `operation:`), run only after the owner's `go`
  # (docs/agents/system/agent-message-loop.md, "Operations"). CODE with bounded
  # params the registry already checked and froze at propose time: no model
  # writes SQL or code, and no operation reaches another app's database (Turf
  # Monster is reached through its operator endpoint, AgentProposals::TurfOperator).
  #
  # NO OPERATION SIGNS. Each stops where the admin's own wallet takes over
  # (AGENTS.md First Rule 10): a cancel is queued for a cosign in Turf's
  # Treasury, a create is a pre-filled form the admin signs in Phantom.
  #
  # FORMATTED IN CODE, as the asks are: the posted text is the board's, from
  # the endpoint's answer, never a model's retelling.
  module Operations
    NAMES = %w[cancel_contest create_contest].freeze

    class Unknown < StandardError; end

    # The operation refused what it was asked (the app's own refusal, or a
    # bound). Its message is operator copy, safe to post.
    class Refused < StandardError; end

    module_function

    # [text to post, result to store] for one confirmed operation.
    def run(name, params, proposal:, client:)
      raise Unknown, "no operation named #{name.inspect}" unless NAMES.include?(name.to_s)

      params = (params || {}).to_h.stringify_keys
      case name.to_s
      when "cancel_contest" then cancel_contest(params, proposal: proposal, client: client)
      when "create_contest" then create_contest(params, client: client)
      end
    rescue TurfOperator::Refused => e
      raise Refused, "Turf refused it: #{e.message}"
    end

    # Who said go, as the run record and the app's pending transaction name it.
    def confirmed_by(proposal)
      person = proposal.confirm_message&.person
      who = person ? "#{person.display_name.to_s.squish[0, 60]} (person #{person.id})" : "unknown"
      "#{who}, go on #{proposal.channel} for agent proposal #{proposal.id}"
    end

    def cancel_contest(params, proposal:, client:)
      answer = client.cancel(slug: params.fetch("contest"), paid_entries: params.fetch("paid_entries", "none"),
                             requested_by: confirmed_by(proposal), request_ref: "agent_proposal:#{proposal.id}")
      treasury = client.url_for(answer["treasury_path"] || "/admin/pending_transactions")
      name = "#{answer['name'].to_s.squish[0, 80]} (`#{answer['slug']}`)"
      paid = answer["paid_entries"].to_i
      lead = if answer["state"] == "already_queued"
               "A cancel of #{name} was already waiting for your cosign, so nothing new was queued:"
             else
               "Cancel of #{name} queued for your cosign:"
             end
      entries = "#{answer['entries'].to_i} entr#{answer['entries'].to_i == 1 ? 'y' : 'ies'}, #{paid} paid"
      owed = if paid.positive?
               " You chose #{answer['paid_entries_choice']} for the paid entries; making them whole is the refund " \
                 "runbook's human step (turf-monster docs/runbooks/cancelled-contest-refunds.md)."
             else
               ""
             end
      text = "#{lead} #{treasury} Nothing is on chain until your wallet signs it there. #{entries}.#{owed}"
      [ text, { "operation" => "cancel_contest", "contest" => answer["slug"], "state" => answer["state"],
                "pending_transaction_id" => answer["pending_transaction_id"], "paid_entries" => paid,
                "paid_entries_choice" => answer["paid_entries_choice"], "url" => treasury }.compact ]
    end

    def create_contest(params, client:)
      answer = client.prepare(week: params.fetch("week"), weeks: params.fetch("weeks", 1),
                              season: params.fetch("season", "regular"), contest_type: params.fetch("contest_type", "medium"))
      url = client.url_for(answer["path"])
      fee = dollars(answer["entry_fee_cents"])
      prize = dollars(answer["prize_cents"])
      text = "Ready to create a #{answer['format']} contest on NFL #{answer['year']} #{answer['weeks']} " \
             "(#{fee} entry, #{answer['max_entries'].to_i} max, #{prize} in prizes): #{url} " \
             "Open it, check the form, and sign the create in Phantom; nothing is created until you do."
      [ text, { "operation" => "create_contest", "weeks" => answer["weeks"], "year" => answer["year"],
                "format" => answer["format"], "url" => url }.compact ]
    end

    def dollars(cents)
      value = cents.to_i / 100.0
      value == value.floor ? "$#{value.to_i}" : format("$%.2f", value)
    end

    # The contests list as text, for the `turf_contests` ask and the scoped
    # lookup of the same name: what a cancel would touch, before it is proposed.
    def contests_text(client:, scope: "open", limit: 10)
      rows = Array(client.contests(scope: scope, limit: limit)["contests"]).grep(Hash)
      return "Turf Monster has no #{scope == 'all' ? '' : 'open '}contests." if rows.empty?

      lines = rows.map do |c|
        state = if c["cancelled"] then "cancelled"
                elsif c["cancel_queued"] then "#{c['status']}, cancel waiting for cosign"
                elsif c["locked"] then "#{c['status']}, locked"
                else c["status"].to_s
                end
        weeks = c["weeks"].present? ? " · #{c['weeks']}" : ""
        "- `#{c['slug']}` #{c['name'].to_s.squish[0, 60]}#{weeks} · #{c['format']} · #{state} · " \
          "#{c['entries'].to_i}/#{c['max_entries'].to_i} entries, #{c['paid_entries'].to_i} paid"
      end
      "Turf Monster contests (#{scope}, newest first):\n#{lines.join("\n")}"
    end
  end
end
