require "set"

module Workspace
  # Walks one Google Drive knowledge source and records what is there — as
  # METADATA. It never downloads a document: the layer is the source of truth,
  # and this index exists only so the app knows what exists and when it changed.
  #
  # THE ONE PROPERTY THIS FILE EXISTS TO HOLD: a document is marked `missing`
  # only after a walk that COMPLETED. The walk upserts as it goes — a document it
  # did see is real whether or not the walk finishes — but "I did not see X, so X
  # is gone" is an inference that is only valid over the WHOLE tree. A network
  # error on page 3 of a 10-page folder must not mark pages 4-10 missing.
  class DriveWalker
    FOLDER_MIME   = "application/vnd.google-apps.folder".freeze
    SHORTCUT_MIME = "application/vnd.google-apps.shortcut".freeze

    # A real Drive tree is a handful of levels deep. The bound is a backstop
    # against a pathological structure, not a tuning knob.
    MAX_DEPTH = 25

    Result = Struct.new(:source, :seen, :added, :changed, :unchanged, :missing, :error,
                        keyword_init: true) do
      def ok? = error.nil?
    end

    def initialize(client: nil, clock: -> { Time.current })
      @client = client
      @clock = clock
    end

    def call(source)
      # A wrong kind is a programming error, so it RAISES rather than becoming a
      # failed Result — and it is checked before the walk's own rescue exists.
      raise ArgumentError, "DriveWalker walks google_drive sources, not #{source.kind}" unless source.kind == "google_drive"

      # A folder is walked AS a named subject, never as an implicit global
      # identity. No workspace, or one not yet proven, is a refusal — not a
      # fallback: falling back is how a walk ends up reading the wrong company.
      account = source.workspace_account
      raise ArgumentError, "#{source.name} has no workspace_account — nothing says whose Drive to read" if account.nil?
      raise ArgumentError, "#{account.domain} is #{account.status}, not active — grant delegation, then bin/rails 'workspace:check[#{account.domain}]'" unless account.active?

      @subject = account.subject
      @started_at = @clock.call
      @counts = Hash.new(0)
      @seen = Set.new

      begin
        walk(source, source.external_root_id, depth: 0, visited: Set.new)
      rescue StandardError => e
        # Record the failure on the source so it is visible, and DO NOT infer
        # anything about the documents this walk never reached.
        source.update_columns(last_walk_error: "#{e.class}: #{e.message}".truncate(500),
                              updated_at: @clock.call)
        return result(source, missing: 0, error: "#{e.class}: #{e.message}")
      end

      # Reached ONLY when the whole tree was read without raising.
      missing = mark_unseen_missing(source)
      source.update!(last_walked_at: @started_at, last_walk_error: nil)
      result(source, missing: missing)
    end

    private

    # Keyed by subject, never memoized flat: @subject is assigned per call, so a
    # REUSED walker would read the second source's folder while still holding
    # the first source's identity. workspace:walk builds a fresh walker per
    # source today, so this closes a latent shape rather than an observed bug —
    # but the memo only became identity-bearing when the subject stopped being a
    # constant, and nothing else would catch it coming back.
    def client
      # @client is the INJECTION seam (tests pass a tree double) and must keep
      # winning. Only the built client is memoized, and it is keyed by subject
      # rather than flat: @subject is assigned per call, so a REUSED walker
      # would otherwise read the second source's folder while still holding the
      # first source's identity. workspace:walk builds a fresh walker per source
      # today, so this closes a latent shape rather than an observed bug — but
      # the memo only became identity-bearing when the subject stopped being a
      # constant, and nothing else would catch it coming back.
      @client || ((@clients ||= {})[@subject] ||= DriveClient.new(subject: @subject))
    end

    # Depth-first over folders. `visited` is what makes it terminate: a Drive
    # file may have several parents, so the same folder can be reachable twice.
    def walk(source, folder_id, depth:, visited:)
      raise "Drive tree deeper than #{MAX_DEPTH} levels under #{source.external_root_id}" if depth > MAX_DEPTH
      return if visited.include?(folder_id)

      visited << folder_id

      client.paged(query: "'#{folder_id}' in parents and trashed = false").each do |file|
        if file.mime_type == FOLDER_MIME
          walk(source, file.id, depth: depth + 1, visited: visited)
        else
          # Shortcuts are RECORDED, never followed: following one could lead the
          # walk out of the folder the operator chose to index.
          record(source, file)
        end
      end
    end

    def record(source, file)
      doc = source.source_documents.find_or_initialize_by(external_id: file.id)
      created = doc.new_record?

      if created
        # Triage fields: set ONCE, from the source's defaults, and never again.
        doc.entity = source.entity
        doc.access = source.access
      end

      prior_version = doc.remote_version
      doc.assign_attributes(remote_attributes(file))
      doc.status = "active"
      doc.last_seen_at = @started_at
      doc.save!

      @seen << file.id
      if created
        @counts[:added] += 1
      elsif prior_version != doc.remote_version
        @counts[:changed] += 1
      else
        @counts[:unchanged] += 1
      end
    end

    def remote_attributes(file)
      {
        title: file.name,
        mime_type: file.mime_type,
        web_url: file.web_view_link,
        owner_email: file.owners&.first&.email_address,
        byte_size: file.size,
        remote_version: file.version&.to_s,
        remote_modified_at: file.modified_time,
        checksum: file.md5_checksum,
        parents: Array(file.parents),
        metadata: {
          "head_revision_id" => file.head_revision_id,
          "can_edit" => file.capabilities&.can_edit,
          "shortcut_target_id" => file.shortcut_details&.target_id,
          "shortcut_target_mime" => file.shortcut_details&.target_mime_type
        }.compact
      }
    end

    # Active documents this COMPLETE walk did not see. Marked, never deleted —
    # a document that comes back (re-shared, restored from trash) is simply
    # active again on the next walk, with its triage intact.
    def mark_unseen_missing(source)
      unseen = source.source_documents.active.where.not(external_id: @seen.to_a)
      unseen.update_all(status: "missing", updated_at: @clock.call)
    end

    def result(source, missing:, error: nil)
      Result.new(source: source, seen: @seen.size, added: @counts[:added], changed: @counts[:changed],
                 unchanged: @counts[:unchanged], missing: missing, error: error)
    end
  end
end
