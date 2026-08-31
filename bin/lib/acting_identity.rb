# frozen_string_literal: true

# ActingIdentity — WHO is `gh` about to act as, asked out loud before a merge lands.
#
# WHY THIS EXISTS. On 2026-08-29 two merges went onto `accepted` under Mr.
# McRitchie's PERSONAL account instead of mcritchie-agent[bot]:
#
#   0ca851f6  ship-must-not-exit-zero        author=alexmcritchie
#   0e1825d6  repoint-ecosystem-build-vault  author=alexmcritchie
#
# Three other merges the same day (6c2ce5bd, 73cc7d1a, 0190b8ea) are correctly
# author=mcritchie-agent[bot], so the field discriminates and this was not an
# artefact of the query. NOBODY CHOSE IT. 1Password hit its account-wide daily
# quota, so bin/gh-token could not mint and returned EMPTY; `GH_TOKEN="$(bin/gh-
# token)"` therefore set GH_TOKEN to the empty string, and an empty GH_TOKEN is
# precisely the value `gh` treats as NOT SET. gh fell back to its keyring, where a
# personal `gho_` OAuth login was signed in, and merged as a human. Every agent had
# been told explicitly not to use the personal credential; none did. gh substituted
# it for them.
#
# THAT IS WHY THIS IS MECHANICAL, NOT PROCEDURAL. The instruction already existed
# and was already followed. What failed was that nothing ever ASKED which account
# was about to perform the write, and the answer is invisible in the output of a
# successful merge — you only learn it later, from the commit's author field, which
# is exactly when it is too late. The check is one cheap API call; the failure it
# prevents is otherwise undetectable until an audit.
#
# THE DISCRIMINATOR: `gh api user`, and it is chosen for a specific reason.
#
#   App INSTALLATION token → 403 "Resource not accessible by integration". An
#                            installation is not a user, so /user has no answer for
#                            it. This refusal IS the proof of a bot.
#   a PERSON (gho_ OAuth, github_pat_, classic PAT)
#                          → 200 with a JSON body carrying "login".
#
# WHAT IT DELIBERATELY IS NOT is a permissions probe. "Can this credential read
# pull requests?" looks like the same question and is not: the DEPLOYER App holds
# PR *read*, so that test calls a perfectly good deployer token an agent token, and
# a personal account with `repo` scope passes it outright — which is the very
# credential we are trying to catch. /user separates BOT from HUMAN, which is the
# axis the audit trail is actually about.
#
# FAIL CLOSED, and the UNKNOWN case is the whole reason to say so. A refusal we
# cannot classify (401 on an expired token, gh missing, no network, a body we
# cannot parse) is NOT permission to merge. An identity that cannot be determined
# is treated exactly like a bad one, because the alternative — merge and hope — is
# what produced the two bad merges. UNKNOWN is however RECOVERABLE, and the caller
# is told so: an expired credential is the ordinary end of a long review session,
# and the fix is to mint and re-ask, not to stop the pipeline. The caller decides,
# because minting is a 1Password read and this module has no business spending one.
#
# THE BLANK-TOKEN CASE IS ANSWERED WITHOUT ASKING GITHUB. If GH_TOKEN is PRESENT
# but blank, that is the 2026-08-29 shape exactly, and we know the answer already:
# gh is about to ignore it and use the keyring. Probing would only tell us which
# human. Naming the empty token instead points at the actual defect — the caller
# that captured a failed mint into a variable and exported it — rather than at the
# innocent account gh reached for. It also costs no network call on the one path
# where the network is least likely to be the problem.
#
# NO TOKEN IS EVER RETURNED, LOGGED, OR ECHOED. This module reads GH_TOKEN only to
# ask whether it is blank, and reports identities and logins, never credentials.
require "json"
require "open3"

module ActingIdentity
  # An App installation token — the only identity permitted to merge.
  APP = :app
  # A signed-in PERSON. Never permitted to merge: the whole two-identity audit
  # model is that `agent` merges and a human does not.
  HUMAN = :human
  # Could not be determined. Refused, and RECOVERABLE by minting a fresh token.
  UNKNOWN = :unknown

  # gh's wording when an APP INSTALLATION token calls an endpoint that only exists
  # for users. Matched on the distinctive phrase rather than the whole sentence,
  # because gh wraps it differently depending on whether it is quoting the API body
  # or its own "gh: … (HTTP 403)" line, and BOTH carry this phrase.
  #
  # NOT /x — extended mode strips the literal spaces, so this would compile as
  # "notaccessiblebyintegration" and match nothing. GhAuthRetry carries the same
  # warning above its own regex, having been bitten by exactly that.
  INTEGRATION_REFUSAL = /not accessible by integration/i

  module_function

  # --- the pure core (no gh, no network) -------------------------------------

  # TRUE when GH_TOKEN is PRESENT but blank — the 2026-08-29 shape.
  #
  # PRESENT-BUT-BLANK AND ABSENT ARE DIFFERENT FACTS, and conflating them is the
  # bug. An ABSENT GH_TOKEN is an ordinary, honest state: the session has not
  # exported one and gh will use its keyring, which may hold a perfectly good bot
  # credential — the probe settles it. A PRESENT-BUT-BLANK GH_TOKEN is a caller
  # that reached for a token, got nothing, and handed the nothing onward; gh reads
  # it as "not set" and silently substitutes something else. Only the second is a
  # defect, so only the second is named as one.
  def blank_token?(env: ENV)
    env.key?("GH_TOKEN") && env["GH_TOKEN"].to_s.strip.empty?
  end

  # Classify one `gh api user` result. PURE, so every branch is unit-reachable
  # without a credential of any kind.
  #
  # THE TWO STREAMS ARE READ FOR DIFFERENT THINGS, and that separation is a bug fix,
  # not tidiness. An earlier draft joined them and parsed the join as JSON; the first
  # integration run put Ruby's "already initialized constant" warnings on stderr, the
  # join stopped being valid JSON, and a PERSON was classified UNKNOWN. It failed
  # closed, so nothing merged — but the operator would have been told "identity could
  # not be determined" about a credential we could name, and sent to mint a token
  # that was never the problem. gh (and anything wrapping it) may print whatever it
  # likes on stderr: a deprecation notice, an upgrade nag, a proxy's chatter. So the
  # LOGIN is read from stdout, which carries the API body and nothing else, while the
  # REFUSAL is matched across both, because which stream carries it varies by gh
  # version and losing it would misfile a good App token.
  #
  # ORDER IS LOAD-BEARING. The integration refusal is checked FIRST because it
  # arrives on a FAILED call — an App token's proof of identity is a non-zero exit,
  # so testing `success` first would throw the evidence away and answer UNKNOWN for
  # the one identity we are trying to admit.
  def classify(stdout, stderr, success)
    return APP if INTEGRATION_REFUSAL.match?("#{stdout}\n#{stderr}")
    # Any other failure — 401 on an expired token, a network error, gh not
    # installed — is a question we could not get an answer to, never an answer.
    return UNKNOWN unless success

    # A 200 from /user means a user exists behind this credential. A body we cannot
    # parse, or one with no login, is not evidence of a bot: it is no evidence at
    # all, and no evidence fails closed.
    login_from(stdout).empty? ? UNKNOWN : HUMAN
  end

  # The "login" of a `gh api user` body, or "" when there is not one to read.
  #
  # TOLERANT BY DESIGN, for the reason above one layer down: the whole-string parse
  # is tried first, and a stray line around the body falls back to the outermost
  # {...} span. Being generous here only ever makes a HUMAN easier to RECOGNISE, and
  # recognising a human is what REFUSES a merge — so the tolerance can add refusals
  # and can never add a merge. A parser that fails closed in the unsafe direction
  # would be the wrong kind of strict.
  def login_from(text)
    body = text.to_s
    login = login_in(body)
    return login unless login.empty?

    first = body.index("{")
    last = body.rindex("}")
    return "" if first.nil? || last.nil? || last < first

    login_in(body[first..last])
  end

  def login_in(text)
    parsed = JSON.parse(text.to_s)
    parsed.is_a?(Hash) ? parsed["login"].to_s.strip : ""
  rescue JSON::ParserError
    ""
  end

  # --- the operator-facing refusals ------------------------------------------
  # Each names the defect at the knob that fixes it. A refusal that says only
  # "identity check failed" sends someone hunting; these say which of the three
  # distinguishable things went wrong.

  def blank_token_message
    "GH_TOKEN is set but EMPTY, and `gh` treats an empty GH_TOKEN as NOT SET — it would " \
      "silently fall back to its keyring, where a personal account may be signed in. That is " \
      "how two merges landed under a human's account on 2026-08-29. Fix the CALL SITE that " \
      "exported it (a failed `bin/gh-token` captured into a variable), or unset GH_TOKEN so " \
      "the keyring's own identity can be checked on its merits."
  end

  def human_message(login)
    who = login.to_s.strip.empty? ? "a person" : login.to_s.strip
    "`gh` is authenticated as #{who} — a PERSON, not a GitHub App installation. Refusing to " \
      "merge: `agent` merges and a human does not, and a merge performed with a personal " \
      "credential is attributed to that human forever. Export an agent App token " \
      "(eval \"$(bin/gh-auth-refresh --export)\") and re-run."
  end

  def unknown_message(detail = nil)
    text = detail.to_s.strip
    "could not determine which account `gh` would act as (`gh api user` gave no usable " \
      "answer#{text.empty? ? '' : ": #{first_line(text)}"}). Refusing to merge: an identity " \
      "that cannot be determined is treated as a bad one, because a merge is not reversible " \
      "and its author field is the audit trail."
  end

  # Refusals are read in a terminal beside other output; a whole 403 body pasted
  # into one buries the sentence that matters.
  def first_line(text)
    line = text.to_s.lines.map(&:strip).reject(&:empty?).first.to_s
    line.length > 200 ? "#{line[0, 197]}..." : line
  end

  # --- the probe --------------------------------------------------------------

  # Run `gh api user` and return [stdout, stderr, success?]. BOTH streams are handed
  # back separately — see `classify` for why joining them was a bug. A caller given
  # only stdout would see an empty string for an App token, whose whole answer is on
  # stderr, and answer UNKNOWN for the one identity we exist to admit; a caller given
  # only the join cannot parse a body that stderr has appended noise to.
  def probe(gh_bin: "gh", env: ENV)
    out, err, status = Open3.capture3(env.to_h, gh_bin.to_s, "api", "user")
    [out.to_s, err.to_s, !status.nil? && status.success?]
  rescue StandardError => e
    # gh missing, PATH wrong, spawn refused. Reported as stderr with no success, which
    # classifies UNKNOWN — a question we could not ask is not an answer.
    ["", "#{e.class}: #{e.message}", false]
  end

  # THE ONE CALL A MERGE MAKES. Returns [identity, message]:
  #
  #   [APP, nil]            merge away — gh will act as a GitHub App installation.
  #   [HUMAN, "…"]          REFUSE, and do not retry: minting cannot fix a signed-in
  #                         person, and the message says which one.
  #   [UNKNOWN, "…"]        REFUSE, but RECOVERABLE — an expired or empty credential
  #                         is the ordinary end of a long session. The caller may
  #                         mint a fresh App token and ask again exactly once.
  #
  # The blank-token case answers UNKNOWN WITHOUT PROBING, so it is recoverable on
  # the same path: minting is precisely what an empty token was missing.
  #
  # TEST SEAM: `prober` swaps the live `gh api user` call for a callable answering
  # [stdout, stderr, success], exactly as GhAuthRetry's GH_AUTH_TOKEN_BIN swaps the token
  # broker, and for the same stated reason — the branches that matter here cannot be
  # produced safely on demand. The HUMAN branch would need a person signed in; the
  # APP branch would need a live installation token; the UNKNOWN branch would need an
  # outage. A seam is the only way all three are reachable from a test, and a branch
  # no test can reach is a branch that ships broken. (`gh_bin` is the OTHER seam, used
  # by the integration tier, which points it at a fake gh and exercises the real
  # subprocess plumbing this callable skips.)
  def check(gh_bin: "gh", env: ENV, prober: nil)
    return [UNKNOWN, blank_token_message] if blank_token?(env: env)

    stdout, stderr, success = (prober || method(:probe)).call(gh_bin: gh_bin, env: env)
    case (identity = classify(stdout, stderr, success))
    when APP then [APP, nil]
    when HUMAN then [HUMAN, human_message(login_from(stdout))]
    # The detail prefers stderr, where gh puts the sentence a blocked operator needs
    # ("Bad credentials (HTTP 401)"), and falls back to stdout when it is silent.
    else [identity, unknown_message(stderr.to_s.strip.empty? ? stdout : stderr)]
    end
  end
end
