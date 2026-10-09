// board/engine_board: how a board page's own chrome (tasks/_board, news/index,
// contents/index) reaches the engine board it wraps (studio/board/_board): the
// board's toast list, its count refresh and its exit animation.
//
// The engine publishes a board's scope from its "studio/board" module:
// scopeFor(element) resolves with it once the board is initialised. That is the
// call the engine's own board controller makes, and it is the one made here.
// An engine whose importmap has no "studio/board" publishes nothing, and there
// the scope is read off the element with Alpine.$data.
//
//   installEngineBoard()                        // app/javascript/application.js
//   window.HubEngineBoard.ready(section)        // a promise for the scope
//   window.HubEngineBoard.scope(section)        // the scope now, or null
//
// A section is the board's root element, [data-test="studio-board"].

export const BOARD_MODULE = "studio/board"
export const BOARD_SELECTOR = '[data-test="studio-board"]'

// Whether the page's importmap pins `name`. A page with no importmap, or one
// that does not parse, pins nothing.
export function importmapPins(doc, name) {
  const tag = doc && doc.querySelector('script[type="importmap"]')
  if (!tag) return false
  try {
    const imports = JSON.parse(tag.textContent || "{}").imports || {}
    return typeof imports[name] === "string"
  } catch (error) {
    return false
  }
}

// The reach, over one document. `published` says which engine this page has.
export function engineBoard({ doc = document, win = window, importer = () => import("studio/board") } = {}) {
  const published = importmapPins(doc, BOARD_MODULE)
  const scopes = new WeakMap()
  const pending = new WeakMap()

  // The scope as Alpine holds it on the element. Null before Alpine is there.
  function alpineScope(section) {
    const alpine = win.Alpine
    return (alpine && typeof alpine.$data === "function") ? alpine.$data(section) : null
  }

  return {
    published,

    // Resolves with the section's board scope, or null when there is none to
    // reach. It never rejects.
    ready(section) {
      if (!section) return Promise.resolve(null)
      if (!published) return Promise.resolve(alpineScope(section))
      if (!pending.has(section)) {
        pending.set(section, Promise.resolve()
          .then(importer)
          .then((board) => board.scopeFor(section))
          .then((scope) => { scopes.set(section, scope); return scope })
          .catch((error) => {
            console.error("[board] the engine board could not be reached", error)
            return null
          }))
      }
      return pending.get(section)
    },

    // The section's board scope now, or null while ready() is still resolving.
    scope(section) {
      if (!section) return null
      if (!published) return alpineScope(section)
      if (!scopes.has(section)) this.ready(section)
      return scopes.get(section) || null
    },

    // Starts resolving every board on the page, so scope() answers by the time
    // a click asks.
    prime() {
      Array.prototype.forEach.call(doc.querySelectorAll(BOARD_SELECTOR), (section) => this.ready(section))
    }
  }
}

// Publishes the reach as window.HubEngineBoard, once, and primes it for this
// page and for each page Turbo brings.
export function installEngineBoard({ win = window, doc = document } = {}) {
  if (win.HubEngineBoard) return win.HubEngineBoard

  const reach = win.HubEngineBoard = engineBoard({ doc, win })
  reach.prime()
  doc.addEventListener("turbo:load", () => reach.prime())
  return reach
}
