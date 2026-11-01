// voice_chat: hold to talk to Alex on /chat (chat/_voice; epic
// .agents/epics/studio-voice.md, card 4). Delegated and inert on every page
// without a [data-voice-chat] section.
//
// THE FLOW, for one take the engine recorder hands over
// (studio:voice-recorder:take {blob, mimeType, durationMs}):
//
//   1. embed it ON THIS DEVICE when the page names an embedder (the person has
//      a saved voice; data-voice-chat-embedder is the /profile voice row's own
//      config), with studio/voice_profile's embedderFor. Any failure, or a model
//      slower than EMBED_WAIT_MS, sends the take without a vector: the server
//      then answers "Someone new" (check no_embedding), never an error.
//   2. POST it to /voice/takes (multipart, X-CSRF-Token), which answers
//      {text, speaker, score, identified, check, duration_ms} and keeps nothing.
//   3. send `text` to the chat on the page (the engine form's own action,
//      /agent_chat/messages) with `voice` {speaker, score, check, duration_ms},
//      then nudge the engine chat to poll so the turn and Alex's typing appear.
//
// Every refusal is a line in [data-voice-chat-status] (set as text) and a state
// on data-voice-chat-state: transcribing, sending, sent, silent, no_speech,
// not_configured, rate_limited, refused, failed. A transcript that could not be
// sent is put in the chat's box, so the words are not lost.
//
// The pure parts are exported for test/javascript/voice_chat_test.js.

export const EMBED_WAIT_MS = 8000
export const NUDGE_TRIES = 6
export const NUDGE_MS = 700

export const MESSAGES = {
  transcribing: "Turning that into words...",
  sending: (name) => `Sending to ${name}...`,
  sent: (speaker) => `Sent. Spoken by ${speaker}.`,
  sentPlain: "Sent.",
  silent: "I couldn't hear anything. Check your microphone and hold to talk again.",
  noSpeech: "I couldn't hear any words in that. Check your microphone and try again.",
  notConfigured: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now.",
  rateLimited: "That's a lot of voice messages in a row. Wait a moment, then hold to talk again.",
  signedOut: "Sign in again to talk.",
  unavailable: "I couldn't transcribe that just now. Try again in a moment.",
  failed: "That recording didn't go through. Try again.",
  offline: "Can't reach the server right now. Try again in a moment.",
  notSent: (name) => `Couldn't send that to ${name}. Your words are in the box; press send to try again.`
}

// "Try again in 40 seconds." from a Retry-After header or a retry_after field.
export function retryHint(seconds) {
  const n = Math.round(Number(seconds))
  if (!Number.isFinite(n) || n <= 0) return ""
  if (n < 60) return ` Try again in ${n} second${n === 1 ? "" : "s"}.`
  const minutes = Math.ceil(n / 60)
  return ` Try again in ${minutes} minute${minutes === 1 ? "" : "s"}.`
}

// What POST /voice/takes's refusal means on the page: {state, message}.
// `body` is the parsed JSON (or {}); `retryAfter` the header, if any.
export function refusalFor(status, body = {}, retryAfter = null) {
  const said = body && typeof body.error === "string" && body.error.trim() ? body.error.trim() : null
  if (status === 401) return { state: "refused", message: MESSAGES.signedOut }
  if (status === 429) {
    return { state: "rate_limited", message: MESSAGES.rateLimited + retryHint(retryAfter ?? (body && body.retry_after)) }
  }
  if (status === 422 && body && body.reason === "no_speech") return { state: "no_speech", message: said || MESSAGES.noSpeech }
  if (status === 503 && body && body.reason === "not_configured") return { state: "not_configured", message: said || MESSAGES.notConfigured }
  if (status === 503) return { state: "failed", message: said || MESSAGES.unavailable }
  if ([413, 415, 422].includes(status)) return { state: "refused", message: said || MESSAGES.failed }
  return { state: "failed", message: MESSAGES.failed }
}

// The message's `voice`, from a 200 answer: only the four fields the chat keeps.
export function voiceMetadata(answer = {}) {
  const score = typeof answer.score === "number" && Number.isFinite(answer.score) ? answer.score : null
  const duration = Number.isInteger(answer.duration_ms) ? answer.duration_ms : null
  return { speaker: String(answer.speaker || "Someone new"), score, check: String(answer.check || "no_embedding"), duration_ms: duration }
}

// The multipart body POST /voice/takes reads (studio-engine docs/VOICE_TRANSCRIPTION.md).
export function takeForm(detail, { embedding = null, model = null } = {}, FormDataClass = globalThis.FormData) {
  const form = new FormDataClass()
  form.append("voice[audio]", detail.blob, "take")
  if (detail.mimeType) form.append("voice[mime_type]", detail.mimeType)
  form.append("voice[duration_ms]", String(Math.max(1, Math.round(Number(detail.durationMs) || 0))))
  if (Array.isArray(embedding) && embedding.length && model) {
    form.append("voice[embedding]", JSON.stringify(embedding))
    form.append("voice[model]", model)
  }
  return form
}

export function parseEmbedder(text) {
  if (!text) return null
  try {
    const config = JSON.parse(text)
    return config && config.name && config.id ? config : null
  } catch (_) {
    return null
  }
}

// The page's token (csrf_meta_tags), else the chat form's own hidden field.
export function csrfToken(doc = globalThis.document) {
  if (!doc || !doc.querySelector) return null
  const meta = doc.querySelector("meta[name='csrf-token']")
  if (meta && meta.getAttribute("content")) return meta.getAttribute("content")
  const field = doc.querySelector("[data-agent-chat-form] input[name='authenticity_token']")
  return field ? field.value : null
}

// Resolves to `promise`'s value, or `fallback` once `ms` have passed.
export function within(promise, ms, fallback = null, setTimer = (fn, t) => globalThis.setTimeout(fn, t)) {
  return Promise.race([promise, new Promise((resolve) => setTimer(() => resolve(fallback), ms))])
}

async function readJson(response) {
  try { return await response.json() } catch (_) { return {} }
}

// Binds one document. Returns { handleTake, destroy } for tests.
export function bindVoiceChat(doc = globalThis.document, {
  fetch: fetcher = (...args) => globalThis.fetch(...args),
  loadEmbedder = async (config) => {
    const { embedderFor } = await import("studio/voice_profile")
    return embedderFor(config)
  },
  setTimer = (fn, ms) => globalThis.setTimeout(fn, ms),
  FormDataClass = globalThis.FormData
} = {}) {
  const embedders = new Map()

  function sectionFor(target) {
    return target && target.closest ? target.closest("[data-voice-chat]") : null
  }

  function chatFor(section) {
    const page = section.closest("[data-voice-chat-page]") || doc
    return page.querySelector("[data-studio-controller='agent-chat']")
  }

  function say(section, state, message) {
    section.dataset.voiceChatState = state
    const status = section.querySelector("[data-voice-chat-status]")
    if (status) status.textContent = message || ""
  }

  function embedderOf(section) {
    const config = parseEmbedder(section.getAttribute("data-voice-chat-embedder"))
    if (!config) return Promise.resolve(null)
    if (!embedders.has(config.id)) {
      const loading = Promise.resolve().then(() => loadEmbedder(config)).catch(() => null)
      embedders.set(config.id, loading)
      loading.then((embedder) => { if (!embedder) embedders.delete(config.id) })
    }
    return embedders.get(config.id)
  }

  async function embed(section, blob) {
    try {
      const embedder = await within(embedderOf(section), EMBED_WAIT_MS)
      if (!embedder) return {}
      const vector = await within(embedder.embed(blob), EMBED_WAIT_MS)
      return Array.isArray(vector) && vector.length ? { embedding: vector, model: embedder.id } : {}
    } catch (_) {
      return {}
    }
  }

  // The engine chat polls on its retry control; a poll already in flight
  // swallows one, so nudge until the new turn is on the page.
  function nudge(chat, id, tries = NUDGE_TRIES) {
    if (!chat) return
    const shown = () => Array.from(chat.querySelectorAll("[data-turn-key]")).some((el) => el.dataset.turnKey === `${id}:user`)
    if (shown() || tries <= 0) return
    const retry = chat.querySelector("[data-agent-chat-retry]")
    if (retry) retry.click()
    setTimer(() => nudge(chat, id, tries - 1), NUDGE_MS)
  }

  function keepWords(chat, text) {
    const input = chat && chat.querySelector("[data-agent-chat-input]")
    if (input && !input.value.trim()) input.value = text
  }

  async function send(section, answer) {
    const chat = chatFor(section)
    const form = chat && chat.querySelector("[data-agent-chat-form]")
    const name = section.dataset.voiceChatName || "the agent"
    const soul = section.dataset.voiceChatSoul || (chat && chat.dataset.agentChatSoul)
    const voice = voiceMetadata(answer)
    if (!form) {
      say(section, "failed", MESSAGES.notSent(name))
      return
    }
    say(section, "sending", MESSAGES.sending(name))
    let response
    try {
      const headers = { Accept: "application/json", "Content-Type": "application/json" }
      const token = csrfToken(doc)
      if (token) headers["X-CSRF-Token"] = token
      response = await fetcher(form.getAttribute("action"), {
        method: "POST", headers, credentials: "same-origin", body: JSON.stringify({ soul, text: answer.text, voice })
      })
    } catch (_) {
      keepWords(chat, answer.text)
      say(section, "failed", MESSAGES.notSent(name))
      return
    }
    const data = await readJson(response)
    if (response.status === 201 && data.turn) {
      // The speaker the row kept (AgentChat::Voice names it on the server),
      // which is what Alex is told; never the browser's own copy.
      const kept = data.voice && typeof data.voice.speaker === "string" ? data.voice.speaker : null
      say(section, "sent", kept ? MESSAGES.sent(kept) : MESSAGES.sentPlain)
      nudge(chat, data.turn.id)
      return
    }
    keepWords(chat, answer.text)
    const reason = typeof data.error === "string" && data.error ? `${data.error} ` : ""
    say(section, response.status === 429 ? "rate_limited" : "failed", `${reason}${MESSAGES.notSent(name)}`)
  }

  async function handleTake(section, detail) {
    if (section.dataset.voiceChatBusy === "true") return
    section.dataset.voiceChatBusy = "true"
    say(section, "transcribing", MESSAGES.transcribing)
    try {
      const vector = await embed(section, detail.blob)
      const headers = { Accept: "application/json" }
      const token = csrfToken(doc)
      if (token) headers["X-CSRF-Token"] = token
      let response
      try {
        response = await fetcher(section.dataset.voiceChatTakesUrl || "/voice/takes", {
          method: "POST", headers, credentials: "same-origin", body: takeForm(detail, vector, FormDataClass)
        })
      } catch (_) {
        say(section, "failed", MESSAGES.offline)
        return
      }
      const body = await readJson(response)
      if (!response.ok || typeof body.text !== "string" || !body.text.trim()) {
        const retryAfter = response.headers && response.headers.get ? response.headers.get("Retry-After") : null
        const { state, message } = response.ok ? { state: "no_speech", message: MESSAGES.noSpeech } : refusalFor(response.status, body, retryAfter)
        say(section, state, message)
        return
      }
      await send(section, body)
    } finally {
      delete section.dataset.voiceChatBusy
    }
  }

  function onTake(event) {
    const section = sectionFor(event.target)
    if (!section || !event.detail || !event.detail.blob) return
    handleTake(section, event.detail)
  }

  function onSilent(event) {
    const section = sectionFor(event.target)
    if (section) say(section, "silent", MESSAGES.silent)
  }

  // Start the model download while the person is still talking.
  function onState(event) {
    const section = sectionFor(event.target)
    if (section && event.detail && event.detail.state === "recording") embedderOf(section).then((e) => e && e.warm && e.warm()).catch(() => {})
  }

  doc.addEventListener("studio:voice-recorder:take", onTake)
  doc.addEventListener("studio:voice-recorder:silent", onSilent)
  doc.addEventListener("studio:voice-recorder:state", onState)

  return {
    handleTake,
    destroy() {
      doc.removeEventListener("studio:voice-recorder:take", onTake)
      doc.removeEventListener("studio:voice-recorder:silent", onSilent)
      doc.removeEventListener("studio:voice-recorder:state", onState)
    }
  }
}

if (typeof document !== "undefined" && typeof window !== "undefined" && !window.__voiceChatBound) {
  window.__voiceChatBound = true
  bindVoiceChat(document)
}
