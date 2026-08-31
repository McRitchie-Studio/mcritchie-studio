# frozen_string_literal: true

require "json"
require_relative "task_board"

# DeskLedger — the desk ledger's WRITE side, from the CLI.
#
# WHAT IT REPLACES. `bin/agent-worktree` used to append its teardown row to
# `docs/agents/maintenance/delete-later.md`, resolved against HUB_DIR. A cleanup is
# normally run from the PRIMARY checkout, and the primary sits on `main` — a branch
# nobody may commit to. So the record was created in the one place it could never be
# saved from: six stashes of "restore later" ledger content between 2026-07-02 and
# 2026-08-31, 98 rows, none restored, plus 25 more stranded by a reclaim sweep that ran
# DURING the conversation about the defect. The board write is durable the moment it
# lands, which is the whole point.
#
# TWO POSTURES, AND THE CALLER PICKS BY WHAT IT IS ABOUT TO DO.
#
#   file!  — the DESTROY path (`remove`, `cleanup --reclaim --yes`, `cleanup --write`).
#            Returns a Result; a failure MUST abort the teardown. bin/agent-worktree
#            calls this BEFORE it stops a stack or drops a worktree, so a refusal costs
#            a retry and nothing else. This is the FAIL-CLOSED half.
#   sync   — the READ-ONLY refresh (`snapshot --write`). Best-effort: the local registry
#            file is still written, nothing is destroyed, so a board outage degrades to
#            a loud warning rather than blocking an operator who is only looking.
#
# WHY NO LOCAL QUEUE. A spool that flushes "on next contact" re-introduces the exact
# failure this replaces — a record that exists only on one machine until somebody
# remembers. Fail-closed costs nothing on the destroy path because the write happens
# FIRST, and the automatic sweeps already withhold every bound desk when the board is
# unreadable (bin/agent-worktree#reclaim_evidence), so a board outage was never a window
# in which mass teardown was safe to begin with.
module DeskLedger
  # Bounded on both ends. A teardown is interactive and a hung socket must not look like
  # a hung sweep; 10s is longer than the board's p99 and far shorter than an operator's
  # patience.
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # ok      — the board accepted the write (2xx)
  # record  — the parsed `data` payload, when there is one
  # error   — a one-line reason, ALWAYS set when ok is false
  Result = Struct.new(:ok, :record, :error, keyword_init: true) do
    def ok? = !!ok
  end

  module_function

  def base_url(env = ENV)
    url = env["TASK_API_BASE"].to_s.strip
    url.empty? ? "https://mcritchie.studio" : url
  end

  # File ONE desk record. `desk` is the registry record verbatim — the same hash
  # `bin/agent-worktree snapshot` builds — so the mapping onto columns lives once, on
  # the server (DeskRecord.registry_attributes).
  def file(desk:, status:, source:, dotenv: nil, env: ENV, resolved_on: nil,
           actor: nil, safety: nil, reason: nil, safe_delete_condition: nil)
    body = {
      desk: {
        worktree_path: desk["worktree"],
        registry: desk,
        status: status,
        resolved_on: resolved_on,
        source: source,
        actor: actor,
        safety: safety,
        reason: reason,
        safe_delete_condition: safe_delete_condition
      }.compact
    }

    post("/api/v1/desk_records", body, dotenv: dotenv, env: env)
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
    return Result.new(ok: true, record: parsed["data"]) if res.code.to_i.between?(200, 299)

    Result.new(ok: false,
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
