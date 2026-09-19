namespace :workspace do
  desc "Prove the Google Workspace credential and name what it can reach (reads nothing else)"
  task check: :environment do
    unless Workspace::Credentials.configured?
      warn "No Google credential. Set GOOGLE_SERVICE_ACCOUNT_JSON, or file it at " \
           "#{Workspace::Credentials::ITEM}."
      exit 1
    end

    key = Workspace::Credentials.credential
    puts "Credential source: #{Workspace::Credentials.source}"
    puts "Service account:   #{key['client_email']}"
    puts "Project:           #{key['project_id']}"
    # Read back off the built authorizer, not off the constant: the subject
    # assignment is a separate line that fails silently when missed.
    puts "Impersonating:     #{Workspace::Credentials.subject}"
    puts "Scopes:"
    Workspace::Credentials::SCOPES.each { |scope| puts "  #{scope}" }
    puts
    puts "Drive:  #{Workspace::DriveClient.new.files_list(query: 'trashed = false', limit: 1).files&.size.to_i} " \
         "file(s) reachable on the first page"
    puts "Gmail:  profile #{Workspace::GmailClient.new.service.get_user_profile('me').email_address}"
  rescue Workspace::Credentials::Malformed => e
    warn "workspace:check FAILED — the credential is filed but unusable: #{e.message}"
    exit 1
  rescue Google::Apis::AuthorizationError, Google::Apis::ClientError => e
    warn "workspace:check FAILED — Google refused: #{e.class}: #{e.message}"
    warn "If this is a 403 on Drive or Gmail, domain-wide delegation is probably not granted " \
         "for all of #{Workspace::Credentials::SCOPES.size} scopes, or the subject " \
         "#{Workspace::Credentials::SUBJECT} does not exist in the domain."
    exit 1
  end

  # --- the knowledge-source metadata index ---------------------------------
  #
  # A source is a knowledge LAYER instance - a shared Drive folder today. Its
  # documents are indexed as METADATA ONLY; nothing is downloaded or copied.

  desc "Register a Drive folder as a knowledge source: workspace:add_source[name,folder_id,entity]"
  task :add_source, [ :name, :folder_id, :entity ] => :environment do |_t, args|
    abort "usage: bin/rails 'workspace:add_source[<name>,<drive folder id>,<entity>]'" if args[:name].blank? || args[:folder_id].blank?

    source = KnowledgeSource.find_or_create_by!(kind: "google_drive", external_root_id: args[:folder_id]) do |s|
      s.name = args[:name]
      s.entity = args[:entity].presence
    end
    puts "source ##{source.id} #{source.name} (#{source.kind} #{source.external_root_id}) entity=#{source.entity || '-'}"
    puts "Access defaults to none for every agent; grant it with a runner, then walk: bin/rails 'workspace:walk[#{source.id}]'"
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
        puts "##{source.id} #{source.name}: #{r.seen} seen - #{r.added} new, #{r.changed} changed, " \
             "#{r.unchanged} unchanged, #{r.missing} now missing; #{source.stale_documents.size} need indexing"
        nil
      else
        # Loud, and nothing was marked missing: a failed walk infers nothing.
        warn "##{source.id} #{source.name}: WALK FAILED - #{r.error} (nothing marked missing)"
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
      puts "##{source.id} [#{source.kind}] #{source.name} - #{docs.active.count} active, #{docs.missing.count} missing, " \
           "#{source.stale_documents.size} need indexing; last complete walk #{walked}" \
           "#{" - LAST WALK FAILED: #{source.last_walk_error}" if source.last_walk_error}"
    end
    puts "(no knowledge sources registered)" if KnowledgeSource.none?
  end
end
