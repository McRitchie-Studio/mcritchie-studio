require Rails.root.join("bin/lib/agent_domain_registry").to_s
require Rails.root.join("bin/lib/agent_proposal_block").to_s

# What a domain agent offered to do in one thread, waiting for the owner's word
# (docs/agents/system/agent-message-loop.md, "Proposals and confirm").
#
#   proposed ──go (owner)──▶ confirmed ──ran──▶ executed
#      │  ▲                      └──failed──▶ proposed (the go can be retried)
#      │  └ a newer proposal in the thread, `no`, or `change: …` ──▶ rejected
#      └──24 hours pass──▶ expired
#
# THE BOARD DECIDES. The model's PROPOSAL block (AgentMailbox::ProposalBlock) is
# only parsed by the worker. record_from! checks it against config/agent_domains.yml
# (AgentMailbox::DomainRegistry#validate): the capability must be in the
# proposing soul's OWN domain, its params must fit the schema, and the sender's
# audience (AgentPerson's role, never the message text) must be allowed to
# request it. A refused proposal is never stored here and never shown: it is a
# `proposal_refused` event on the message that carried it.
#
# ONE OPEN PROPOSAL PER THREAD. A new one rejects the one before it, so a bare
# `go` means the newest offer. A `go` sent as a Discord reply to one proposal's
# message is about THAT proposal (for_word): if it is no longer open, the owner is
# told and nothing runs, never the newer offer in its place.
class AgentProposal < ApplicationRecord
  STATUSES = %w[proposed confirmed rejected expired executed].freeze
  KINDS = AgentMailbox::DomainRegistry::KINDS
  TTL = 24.hours
  # What the owner is told under an accepted proposal.
  CONFIRM_LINE = "Reply **go** to run this, **no** to drop it, or **change: …**".freeze
  BOARD_URL = "https://mcritchie.studio".freeze
  RUNS_LINE_LIMIT = 600
  PARAM_VALUE_LIMIT = 120

  belongs_to :person, class_name: "AgentPerson", optional: true
  belongs_to :source_message, class_name: "AgentMessage", optional: true
  belongs_to :confirm_message, class_name: "AgentMessage", optional: true

  validates :thread_key, :channel, :channel_ref, :soul_slug, :capability, :expires_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :kind, inclusion: { in: KINDS }

  scope :pending, -> { where(status: "proposed") }

  class << self
    # The registry, read once per process. Tests swap it with `registry=`.
    def registry = @registry ||= AgentMailbox::DomainRegistry.load

    attr_writer :registry

    def reset_registry! = @registry = nil

    # The sender's audience, as AgentMailbox::Audience: from the person's role
    # (AgentPerson.audience_for), so nothing a message says can raise it.
    def audience_for(person)
      data = AgentPerson.audience_for(person)
      AgentMailbox::Audience.new(role: data["role"], client_domain: data["client_domain"])
    end

    # Check the parsed PROPOSAL block a completed answer carried and store it, or
    # log why not. Returns the new proposal, or nil. Called inside complete!'s
    # transaction, so the proposal and the answer land together.
    def record_from!(message, raw, now: Time.current)
      return nil if raw.nil?

      # The audience the answer was given as (MemoryBundle#audience): an app
      # owner on their own CTO thread is that app's client, a /build turn the public.
      bundle_audience = AgentMessages::MemoryBundle.new(message).audience
      audience = AgentMailbox::Audience.new(role: bundle_audience["role"], client_domain: bundle_audience["client_domain"])
      verdict = registry.validate(soul: message.soul_slug, audience: audience, proposal: raw)
      unless verdict.ok?
        message.record!("proposal_refused", actor: "board",
                                            detail: { "reason" => verdict.reason.to_s[0, 300],
                                                      "capability" => raw.is_a?(Hash) ? raw["capability"].to_s[0, 60] : nil }.compact)
        return nil
      end

      data = verdict.proposal
      in_thread(message).pending.find_each { |older| older.settle!("rejected", by: "board", now: now, result: { "reason" => "superseded" }) }
      proposal = create!(thread_key: message.thread_key, channel: message.channel, guild_id: message.guild_id,
                         channel_ref: message.channel_ref, soul_slug: message.soul_slug, person: message.person,
                         source_message: message, kind: data["kind"], capability: data["capability"],
                         params: data["params"], summary: data["summary"], expires_at: now + TTL)
      message.record!("proposed", actor: "board", detail: { "proposal_id" => proposal.id, "kind" => proposal.kind,
                                                            "capability" => proposal.capability })
      proposal
    end

    # Proposals in the same conversation as `row` (a message or a hash of its
    # scope), scoped as the THREAD layer is: key, channel, guild and channel ref.
    def in_thread(row)
      where(thread_key: row.thread_key, channel: row.channel, guild_id: row.guild_id, channel_ref: row.channel_ref)
    end

    # The proposal an owner's word is about. A word that is a Discord reply to
    # the message that posted a proposal (its source message's reply, or that
    # message itself) is about THAT proposal, whatever its status: the caller
    # tells the owner when it is no longer open rather than running another.
    # Any other word is about the newest pending proposal in the thread.
    def for_word(thread_key:, channel:, guild_id:, channel_ref:, reference_id: nil)
      scope = where(thread_key: thread_key, channel: channel, guild_id: guild_id, channel_ref: channel_ref)
      if reference_id.present?
        named = scope.joins(:source_message)
                     .where("agent_messages.reply_external_id = :ref OR agent_messages.external_id = :ref",
                            ref: reference_id.to_s)
                     .order(id: :desc).first
        return named if named
      end
      scope.pending.order(id: :desc).first
    end

    # The newest still-pending proposal in a thread, or nil (expired ones included:
    # the caller expires them, so a late `go` is told).
    def latest_pending(thread_key:, channel:, guild_id:, channel_ref:)
      where(thread_key: thread_key, channel: channel, guild_id: guild_id, channel_ref: channel_ref)
        .pending.order(id: :desc).first
    end
  end

  def expired?(now = Time.current) = status == "expired" || (status == "proposed" && expires_at <= now)

  # Move to a terminal or waiting status, stamping who and when.
  def settle!(new_status, by:, now: Time.current, result: nil)
    update!(status: new_status, settled_at: now, settled_by: by.to_s[0, 100], result: result || self.result)
  end

  # The lines appended under the answer that carried it: the model's summary,
  # then what will actually run, rendered HERE from the stored kind, capability
  # and params (the values the registry checked), so the owner confirms the call
  # itself and not only the model's description of it.
  def confirm_text = "> Proposed: #{summary}\n> Runs: #{runs_line}\n#{CONFIRM_LINE}"

  # `ask recently_shipped · days 7`, `change task · title Footer… · accept A; B`.
  def runs_line
    parts = params.to_h.map { |key, value| "#{key} #{param_text(value)}" }
    line = [ "#{kind} `#{capability}`", *parts ].join(" · ")
    parts.empty? ? "#{line} (no params)" : line.truncate(RUNS_LINE_LIMIT)
  end

  # The bundle's view of it, for the next answer's context (`change: …`).
  def as_context_json
    { "id" => id, "kind" => kind, "capability" => capability, "params" => params, "summary" => summary,
      "status" => status, "expires_at" => expires_at.iso8601 }
  end

  # One param value as plain text: a list joined with "; ", every piece cut to
  # PARAM_VALUE_LIMIT, backticks and newlines removed so a value cannot break
  # out of the line.
  def param_text(value)
    pieces = value.is_a?(Array) ? value : [ value ]
    pieces.map { |v| v.to_s.delete("`").squish.truncate(PARAM_VALUE_LIMIT) }.join("; ")
  end

  def task_url(slug) = "#{BOARD_URL}/tasks/#{slug}"

  # The admin page of the message that carried the proposal, or nil.
  def message_url = source_message_id ? "#{BOARD_URL}/admin/agent_messages/#{source_message_id}" : nil

  # Where the request was made, as a task's description names it.
  def requested_in
    case channel
    when "email" then "email"
    when "web" then "the #{channel_ref} web chat"
    when "slack" then "Slack"
    when "teams" then "Teams"
    else "Discord"
    end
  end

  # The link to the message that carried it: the thread a task records. Discord's
  # own link; an email thread has none, so its admin page on the board. A web-chat
  # thread is the app's chat page (channel_ref is the app slug), where its owner
  # reads it; the message's admin page is message_url.
  def thread_url
    return "#{BOARD_URL}/applications/#{channel_ref}/chat" if channel == "web" && channel_ref.to_s.match?(/\A[a-z0-9-]+\z/)
    return "#{BOARD_URL}/admin/agent_messages/#{source_message_id}" if channel == "email" && source_message_id
    # Slack and Teams: the medium's own link to the message, else its admin page.
    if %w[slack teams].include?(channel)
      link = source_message && Media.adapter(channel)&.message_url(source_message)
      return link.presence || (source_message_id ? "#{BOARD_URL}/admin/agent_messages/#{source_message_id}" : nil)
    end

    source_message&.discord_url || (guild_id.present? ? "https://discord.com/channels/#{guild_id}/#{channel_ref}" : nil)
  end
end
