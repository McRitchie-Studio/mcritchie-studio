namespace :workspace do
  # A Google Workspace we hold agentic access to. One service account serves
  # every workspace; the per-workspace step is that domain's super-admin
  # granting delegation in their own admin console, which Google offers no API
  # for. These tasks cover everything either side of that one click.

  desc "Register a Google Workspace: workspace:register[domain,name,entity] (subject defaults to team@domain)"
  task :register, [ :domain, :name, :entity ] => :environment do |_t, args|
    abort "usage: bin/rails 'workspace:register[<domain>,<name>,<entity>]'" if args[:domain].blank?

    account = WorkspaceAccount.find_or_initialize_by(domain: args[:domain].to_s.strip.downcase)
    account.name = args[:name].presence || account.name
    account.entity = args[:entity].presence || account.entity
    account.scopes = Workspace::Credentials::SCOPES
    account.save!

    puts "#{account.domain} registered — acting as #{account.subject} (#{account.status})"
    puts
    puts "Hand this to that domain's super-admin (admin.google.com → Security → Access and data"
    puts "control → API controls → Manage domain wide delegation → Add new):"
    puts "  Client ID: #{(Workspace::Credentials.credential || {})['client_id'] || '(no credential filed)'}"
    puts "  Scopes:    #{Workspace::Credentials::SCOPES.join(',')}"
    puts
    puts "Then prove it: bin/rails 'workspace:check[#{account.domain}]'"
  end

  desc "List registered workspaces and whether their delegation is proven"
  task accounts: :environment do
    WorkspaceAccount.order(:domain).each do |a|
      verified = a.delegation_verified_at ? a.delegation_verified_at.utc.iso8601 : "never"
      puts "#{a.domain.ljust(28)} #{a.status.ljust(8)} acting as #{a.subject.ljust(30)} verified #{verified}" \
           "#{" — last refusal: #{a.last_check_error}" if a.last_check_error}"
    end
    puts "(no workspaces registered — bin/rails 'workspace:register[<domain>]')" if WorkspaceAccount.none?
  end

  desc "Prove one workspace's delegation and flip it active: workspace:check[domain]"
  task :check, [ :domain ] => :environment do |_t, args|
    unless Workspace::Credentials.configured?
      warn "No Google credential. Set GOOGLE_SERVICE_ACCOUNT_JSON, or file it at #{Workspace::Credentials::ITEM}."
      exit 1
    end

    accounts = args[:domain].present? ? WorkspaceAccount.where(domain: args[:domain].to_s.strip.downcase) : WorkspaceAccount.all
    abort "No workspace matches #{args[:domain].inspect}. Register it first." if accounts.none?

    key = Workspace::Credentials.credential
    puts "Credential source: #{Workspace::Credentials.source} · service account #{key['client_email']} · client id #{key['client_id']}"

    # A revoked row is never PROBED, let alone flipped. Skipping it here is what
    # keeps this sweep truthful — the probe gate is `exists?` rather than
    # `active?` on purpose, so that pending rows can be proven, which means a
    # revoked row would otherwise probe green and print "ACTIVE" for a mailbox
    # that stays shut. The model refuses the flip as well; these are two
    # independent halves of the same guarantee, and neither relies on the other.
    revoked, checkable = accounts.order(:domain).to_a.partition { |account| account.status == "revoked" }

    revoked.each do |account|
      puts "#{account.domain}: SKIPPED — revoked, so impersonation stays refused and delegation was not probed."
      puts "  → bin/rails 'workspace:reinstate[#{account.domain}]' returns it to pending, where a check can prove it again."
    end

    failed = checkable.map { |account|
      begin
        ok, error = Workspace::Credentials.probe(account.subject)
        unless ok
          # unauthorized_client is the NORMAL not-yet state for a fresh grant —
          # and also exactly what a grant placed in the WRONG workspace looks
          # like, forever. Naming the domain is what tells those apart.
          account.mark_unverified!(error)
          warn "#{account.domain}: NOT AUTHORIZED as #{account.subject} (#{error})"
          warn "  → the delegation must be granted in #{account.domain}'s OWN admin console, for client id #{key['client_id']}"
          next account
        end

        if account.scopes.present? && account.scopes != Workspace::Credentials::SCOPES
          warn "  → #{account.domain} was registered against different scopes than the code now asks for;"
          warn "    re-run workspace:register[#{account.domain}] and have the delegation re-granted."
        end

        # The flip comes BEFORE the two reads deliberately: DriveClient and
        # GmailClient both go through authorizer_for, which refuses a subject
        # that is not ACTIVE. So the reads are a smoke test of a grant already
        # proven by the probe, not the proof itself — they cannot be reordered.
        account.mark_verified!
        drive = Workspace::DriveClient.new(subject: account.subject).files_list(query: "trashed = false", limit: 5)
        profile = Workspace::GmailClient.new(subject: account.subject).service.get_user_profile("me")
        puts "#{account.domain}: ACTIVE as #{account.subject}"
        puts "  mailbox: #{profile.email_address} (#{profile.messages_total} messages)"
        puts "  drive:   #{Array(drive.files).size} item(s) on the first page"
        nil
      rescue StandardError => e
        # One row's failure must not abandon the rest of the sweep half-checked,
        # which is what an exception escaping this block used to do — including
        # after that row had already been flipped active.
        warn "#{account.domain}: CHECK FAILED (#{e.class}: #{e.message})"
        next account
      end
    }.compact

    exit 1 if failed.any?
  end

  desc "Switch a workspace OFF: workspace:revoke[domain,reason]"
  task :revoke, [ :domain, :reason ] => :environment do |_t, args|
    abort "usage: bin/rails 'workspace:revoke[<domain>,<why>]'" if args[:domain].blank?

    account = WorkspaceAccount.find_by(domain: args[:domain].to_s.strip.downcase)
    abort "No workspace registered for #{args[:domain]}." if account.nil?

    account.revoke!(args[:reason])
    puts "#{account.domain}: REVOKED — impersonating #{account.subject} is refused from the next call."
    puts "  Kept: the row and its #{account.knowledge_sources.count} knowledge source(s), so what we already read stays readable."
    puts "  Nothing reactivates this on its own — not even a successful workspace:check."
    puts "  Back: bin/rails 'workspace:reinstate[#{account.domain}]' (to PENDING, which must then be re-proven)."
    puts
    puts "  ⚠ This is the LOCAL half only. The Google-side grant is untouched and still exists."
    puts "    To end it, #{account.domain}'s super-admin removes client id " \
         "#{(Workspace::Credentials.credential || {})['client_id'] || '(no credential filed)'} from their delegation page."
  end

  desc "Return a revoked workspace to pending (delegation must be re-proven): workspace:reinstate[domain]"
  task :reinstate, [ :domain ] => :environment do |_t, args|
    abort "usage: bin/rails 'workspace:reinstate[<domain>]'" if args[:domain].blank?

    account = WorkspaceAccount.find_by(domain: args[:domain].to_s.strip.downcase)
    abort "No workspace registered for #{args[:domain]}." if account.nil?

    begin
      account.reinstate!
    rescue ArgumentError => e
      abort e.message
    end

    puts "#{account.domain}: now PENDING — impersonation is STILL refused."
    puts "  Reinstating does not restore access; it only makes the grant provable again."
    puts "  Prove it: bin/rails 'workspace:check[#{account.domain}]'"
  end

  desc "Attach a Drive folder to a workspace: workspace:add_source[domain,name,folder_id,entity]"
  task :add_source, [ :domain, :name, :folder_id, :entity ] => :environment do |_t, args|
    abort "usage: bin/rails 'workspace:add_source[<domain>,<name>,<drive folder id>,<entity>]'" if args[:domain].blank? || args[:folder_id].blank?

    account = WorkspaceAccount.find_by(domain: args[:domain].to_s.strip.downcase)
    abort "No workspace registered for #{args[:domain]}. bin/rails 'workspace:register[#{args[:domain]}]' first." if account.nil?

    source = KnowledgeSource.find_or_create_by!(kind: "google_drive", external_root_id: args[:folder_id]) do |s|
      s.name = args[:name].presence || args[:folder_id]
      s.entity = args[:entity].presence || account.entity
      s.workspace_account = account
    end
    source.update!(workspace_account: account) if source.workspace_account_id.nil?

    puts "source ##{source.id} #{source.name} — walked as #{account.subject} (#{account.domain})"
    puts "Access defaults to none for every agent. Walk it: bin/rails 'workspace:walk[#{source.id}]'"
  end

  desc "Walk knowledge sources and record document METADATA: workspace:walk[source_id] (all enabled when omitted)"
  task :walk, [ :source_id ] => :environment do |_t, args|
    sources = args[:source_id].present? ? KnowledgeSource.where(id: args[:source_id]) : KnowledgeSource.enabled
    sources = sources.where(kind: "google_drive")
    abort "No google_drive knowledge source matches #{args[:source_id].inspect}." if sources.none?

    unless Workspace::Credentials.configured?
      warn "No Google credential. Set GOOGLE_SERVICE_ACCOUNT_JSON, or file it at #{Workspace::Credentials::ITEM}."
      exit 1
    end

    failed = sources.map { |source|
      r = Workspace::DriveWalker.new.call(source)
      if r.ok?
        puts "##{source.id} #{source.name}: #{r.seen} seen — #{r.added} new, #{r.changed} changed, " \
             "#{r.unchanged} unchanged, #{r.missing} now missing; #{source.stale_documents.size} need indexing"
        nil
      else
        # Loud, and nothing was marked missing: a failed walk infers nothing.
        warn "##{source.id} #{source.name}: WALK FAILED — #{r.error} (nothing marked missing)"
        source
      end
    }.compact
    exit 1 if failed.any?
  end

  desc "List knowledge sources, their document counts, and what needs indexing"
  task sources: :environment do
    KnowledgeSource.order(:id).each do |source|
      docs = source.source_documents
      walked = source.last_walked_at ? source.last_walked_at.utc.iso8601 : "never"
      as = source.workspace_account ? "as #{source.workspace_account.subject}" : "NO WORKSPACE — cannot walk"
      puts "##{source.id} [#{source.kind}] #{source.name} #{as} — #{docs.active.count} active, #{docs.missing.count} missing, " \
           "#{source.stale_documents.size} need indexing; last complete walk #{walked}" \
           "#{" — LAST WALK FAILED: #{source.last_walk_error}" if source.last_walk_error}"
    end
    puts "(no knowledge sources registered)" if KnowledgeSource.none?
  end
end
