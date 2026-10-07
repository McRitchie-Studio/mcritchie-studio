# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "task_board"

# DeskLedger — the desk ledger's WRITE side, from the CLI.
#
# WHAT IT REPLACES. `bin/agent-worktree` used to append its teardown row to
# `docs/agents/maintenance/delete-later.md`, resolved against HUB_DIR. A cleanup is
# normally run from the PRIMARY checkout, and the primary sits on `main` — a branch
# nobody may commit to. So the record was created in the one place it could never be
# saved from: twelve stashes of "restore later" ledger content between 2026-06-26 and
# 2026-08-31, 166 rows, none restored, plus 25 more stranded by a reclaim sweep that ran
# DURING the conversation about the defect. The board write is durable the moment it
# lands, which is the whole point.
#
# TWO POSTURES, AND THE CALLER PICKS BY WHAT IT IS ABOUT TO DO.
#
#   file_or_queue — the DESTROY path (`remove`, `cleanup --reclaim --yes`, `cleanup
#            --write`). bin/agent-worktree calls it BEFORE it stops a stack or drops a
#            worktree. A record the board does not take is queued (below); only a board
#            that answers with a refusal, or a queue that cannot be written, aborts the
#            teardown. The teardown's SECOND write (closing its `removing` episode
#            `removed` or `leaked`) comes after the desk is gone and is queued the same way.
#   sync   — the READ-ONLY refresh (`snapshot --write`). Best-effort: the local registry
#            file is still written, nothing is destroyed, so a board outage degrades to
#            a loud warning rather than blocking an operator who is only looking.
#
# THE QUEUE (guard catalog row 5.5). A board that does not answer used to refuse every
# teardown, so a board outage blocked an operator's explicit `remove`. Now `file_or_queue`
# appends a record the board could not take to a local queue file, and every later write
# through it posts the queue first, in order, so the record reaches the board the next
# time anything writes to it. The markdown ledger stranded rows because it lived in a
# primary checkout nobody could commit from; the queue lives in the projects root's
# .agents state and empties itself. A board that ANSWERS with a refusal (a 4xx other than
# auth) is not queued: that is the board's verdict, and the caller keeps its posture.
module DeskLedger
  # Bounded on both ends. A teardown is interactive and a hung socket must not look like
  # a hung sweep; 10s is longer than the board's p99 and far shorter than an operator's
  # patience.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # ok      — the board accepted the write (2xx)
  # record  — the parsed `data` payload, when there is one
  # error   — a one-line reason, ALWAYS set when ok is false
  # created — 201 (the board WROTE a row) vs 200 (it already held it). Carried so an
  #           idempotent import can report what it actually did: a second harvest that
  #           counted 200s as successes would claim 166 writes it never performed.
  # code    — the HTTP status when the board answered, nil when it did not
  # queued  — the record could not be posted and is waiting in the local queue
  Result = Struct.new(:ok, :record, :error, :created, :code, :queued, keyword_init: true) do
    def ok? = !!ok
    def queued? = !!queued
  end

  # Statuses that mean "the board did not take it, try again later": auth (the token or
  # secret), timeouts, rate limits and every 5xx. Any other 4xx is the board's answer.
  RETRYABLE_CODES = [401, 403, 408, 429].freeze

  module_function

  def base_url(env = ENV)
    url = env["TASK_API_BASE"].to_s.strip
    url.empty? ? "https://mcritchie.studio" : url
  end

  # File ONE desk record. `desk` is the registry record verbatim — the same hash
  # `bin/agent-worktree snapshot` builds — so the mapping onto columns lives once, on
  # the server (DeskRecord.registry_attributes). `leaked_processes` is the evidence a
  # `leaked` close carries: each process the teardown spared.
  def file(desk:, status:, source:, dotenv: nil, env: ENV, **narrative)
    post("/api/v1/desk_records", desk_body(desk: desk, status: status, source: source, **narrative),
         dotenv: dotenv, env: env)
  end

  # File ONE desk record, or queue it when the board does not answer. Posts the queue
  # first, so records reach the board in the order they were made; while anything is
  # still queued this record joins the back of the queue. Returns the post's Result, or
  # one with `queued: true`. A queue that cannot be written comes back not ok and not
  # queued, and the caller decides.
  def file_or_queue(queue:, dotenv: nil, env: ENV, **record)
    flush(queue: queue, dotenv: dotenv, env: env)
    body = desk_body(**record)
    unless pending(queue).empty?
      return enqueue(queue, body, "earlier records are still queued for #{base_url(env)}")
    end

    result = post("/api/v1/desk_records", body, dotenv: dotenv, env: env)
    return result if result.ok? || !retryable?(result)

    enqueue(queue, body, result.error)
  end

  # Post every queued record in order, stopping at the first the board does not take.
  # A record the board answers with a refusal is dropped with a warning: retrying it
  # would hold the queue forever. Returns the number posted.
  def flush(queue:, dotenv: nil, env: ENV)
    posted = 0
    with_queue_lock(queue) do
      bodies = queued_bodies(queue)
      remaining = bodies.drop_while do |body|
        result = post("/api/v1/desk_records", body, dotenv: dotenv, env: env)
        if result.ok?
          posted += 1
        elsif !retryable?(result)
          warn "desk ledger: dropped a queued record the board refused (#{result.error})"
        end
        result.ok? || !retryable?(result)
      end
      write_queue(queue, remaining) unless remaining.size == bodies.size
    end
    posted
  rescue SystemCallError
    posted
  end

  def pending(queue)
    File.file?(queue) ? File.readlines(queue).reject { |line| line.strip.empty? } : []
  rescue SystemCallError
    []
  end

  def retryable?(result)
    result.code.nil? || result.code >= 500 || RETRYABLE_CODES.include?(result.code)
  end

  def enqueue(queue, body, reason)
    with_queue_lock(queue) do
      write_queue(queue, queued_bodies(queue) + [body])
    end
    Result.new(ok: false, queued: true, error: reason)
  rescue SystemCallError => e
    Result.new(ok: false, error: "#{reason}; and the local queue #{queue} could not be written (#{e.class}: #{e.message})")
  end

  # The lock is a sibling file, because the queue itself is replaced by rename: a lock
  # held on the old inode would not exclude a writer that opens the new one.
  def with_queue_lock(queue)
    FileUtils.mkdir_p(File.dirname(queue))
    File.open("#{queue}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  def queued_bodies(queue)
    return [] unless File.file?(queue)

    File.readlines(queue).filter_map { |line| JSON.parse(line) rescue nil }
  end

  # Temp file plus rename(2): a crash mid-write leaves the old queue or the new one,
  # never a truncated half of either.
  def write_queue(queue, bodies)
    temp = "#{queue}.tmp-#{Process.pid}"
    File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      bodies.each { |body| file.puts(JSON.generate(body)) }
      file.flush
      file.fsync
    end
    File.rename(temp, queue)
  ensure
    FileUtils.rm_f(temp) if temp && File.exist?(temp)
  end

  def desk_body(desk:, status:, source:, resolved_on: nil, actor: nil, safety: nil, reason: nil,
                safe_delete_condition: nil, leaked_processes: nil)
    {
      desk: {
        worktree_path: desk["worktree"],
        registry: desk,
        status: status,
        resolved_on: resolved_on,
        source: source,
        actor: actor,
        safety: safety,
        reason: reason,
        safe_delete_condition: safe_delete_condition,
        leaked_processes: leaked_processes
      }.compact
    }
  end

  # Import ONE stranded ledger row. Distinct from `file` because that path resolves an
  # existing record through the OPEN episode for the desk path, and every stranded row is
  # a RESOLVED teardown that no open episode matches — so `file` would write a duplicate
  # on every re-run. The board keys this write on `import_key` instead, and answers 200
  # rather than 201 for a row it already holds.
  def import(attributes:, dotenv: nil, env: ENV)
    post("/api/v1/desk_records", { desk: attributes.merge(status: "removed") }, dotenv: dotenv, env: env)
  end

  # Fold a whole snapshot registry in. `registry` is the parsed snapshot payload.
  def sync(registry, dotenv: nil, env: ENV)
    post("/api/v1/desk_records/sync", { registry: registry }, dotenv: dotenv, env: env)
  end

  # ---- transport ----------------------------------------------------------
  #
  # NO EXCEPTION ESCAPES. Every failure — a missing secret, a refused connection, a
  # timeout, a 500, a body that will not parse — comes back as a Result whose `error`
  # says which. The caller's posture is the caller's to choose, and a raised
  # SocketError deep inside a teardown would take that choice away from it.
  def post(path, body, dotenv: nil, env: ENV)
    tok = token(dotenv: dotenv, env: env)
    return Result.new(ok: false, error: tok[:error]) unless tok[:token]

    res = TaskBoard.request(:post, path, base_url: base_url(env), token: tok[:token],
                                         body: body, read_timeout: READ_TIMEOUT)
    parsed = TaskBoard.parse_body(res)
    if res.code.to_i.between?(200, 299)
      return Result.new(ok: true, record: parsed["data"], created: res.code.to_i == 201, code: res.code.to_i)
    end

    Result.new(ok: false, code: res.code.to_i,
               error: "POST #{path} -> #{res.code}: #{parsed["error"] || res.body.to_s[0, 200]}")
  rescue StandardError => e
    Result.new(ok: false, error: "POST #{path} failed: #{e.class}: #{e.message}")
  end

  # The 24h bearer, minted per process exactly as bin/task mints its own. Returns
  # { token: } or { error: } — never a bare nil, because "no token" and "no secret" need
  # different remedies and the abort message names one of them.
  def token(dotenv: nil, env: ENV)
    return { token: @token } if defined?(@token) && @token

    secret = TaskBoard.agent_secret(dotenv)
    if secret.to_s.strip.empty?
      return { error: "AGENT_API_SECRET not found (checked ENV, #{dotenv || "the repo .env"}, 1Password)" }
    end

    res = TaskBoard.request(:post, "/api/v1/auth", base_url: base_url(env),
                                                   body: { secret: secret }, read_timeout: READ_TIMEOUT)
    parsed = TaskBoard.parse_body(res)
    tok = parsed["token"]
    return { error: "POST /api/v1/auth -> #{res.code}: #{parsed["error"] || res.code}" } if tok.to_s.empty?

    @token = tok
    { token: tok }
  rescue StandardError => e
    { error: "POST /api/v1/auth failed: #{e.class}: #{e.message}" }
  end
end
