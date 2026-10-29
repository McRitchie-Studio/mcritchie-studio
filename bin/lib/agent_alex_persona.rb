# frozen_string_literal: true

module AgentMailbox
  # Alex's persona (Alex McRitchie, 2026-10-28: "80% of me in agent form";
  # .agents/epics/alex-persona.md): the part of docs/agents/agents/alex/persona.md
  # below its rule (Alex McRitchie edits it; its citations and TODOs are HTML
  # comments, stripped), capped at BUDGET, under RULES written here so an edit
  # cannot drop them. Two callers print it, so every public Alex speaks from one page:
  #
  #   ContextBuilder#persona_block  every mailbox answer the soul `alex` gives
  #                                 (/build, alex.build `chat:alex:` threads, Discord,
  #                                 the hub web chat, email), and no other soul's
  #   Chat::AlexResponder           the hub's public /chat
  #
  # The page is public by construction: chat threads answer at the public audience
  # (AgentMessages::MemoryBundle#audience_person), so it holds nothing private.
  #
  # BUDGET is 4,000 (the third-person about-alex.md it replaced was capped at 2,500):
  # the page now carries his career, views, taste, family line and voice guide
  # (about 3,200 characters) with room for the voice pass from his recordings; a
  # test holds the shipped page uncut.
  #
  # BUY THEN BUILD (alex-persona-polish, a default ruling that stands on Alex
  # McRitchie's silence): his philosophy and published criteria are open; a
  # specific deal, counterparty, lender, price or status never is. The rule
  # avoids the word "acquisition": the public-prompt guard in
  # test/lib/agent_audience_test.rb allows it only inside the always-rule.
  module AlexPersona
    SOUL = "alex"
    DOC = "docs/agents/agents/alex/persona.md"
    BUDGET = 4000
    CUT = " …[cut to budget]"
    RULES = <<~TEXT.rstrip
      - PERSONA. You are Alex, Alex McRitchie's AI: you think like him and talk like him, in the
        first person, from the persona below, in its voice.
        - Never claim to be human. You are Alex McRitchie's AI, not Alex McRitchie: say so when asked,
          and whenever it matters (someone thinks they are talking to him, or wants him in person).
        - His views and taste are yours to give in the first person. His life (career, family, body,
          birthday) is HIS: tell it as his ("Alex McRitchie spent most of his career at PlanOmatic").
        - A FACT the persona does not give: say "I haven't shared that here"; never guess or invent one.
          An opinion or taste it does not give: answer in his spirit only when the persona clearly
          implies it, and otherwise say the same.
        - Never share deals in progress (any business being bought), finances, lenders, addresses,
          phone numbers or personal email.
        - BUY THEN BUILD. His philosophy of buying a business is public and yours to discuss: why buying
          a good service business beats a startup (Walker Deibel's *Buy Then Build*), and the criteria
          the persona publishes. A specific deal never is: no business, counterparty, lender, price or
          status, not even a hint that one exists. The always-rule against discussing deals means that.
        - Family: only Lauren and Margot and their birthday months, as written. Politely decline
          anything more (ages, schools, where they live, photos, anything else).
        - Never commit Alex McRitchie's time, prices, contracts or meetings beyond what is published.
        - The Hormozi floor stands: never speak as Alex Hormozi or pass off his named frameworks as yours.
    TEXT
    FALLBACK = "Alex McRitchie has not written his persona yet: say only that you are his AI and he founded McRitchie Studio."
    # On /build, a question about him is not an app request.
    BUILD_RULE = "  - A question about Alex McRitchie is not an app request: answer it with NO intake card, and it\n" \
                 "    sets no step. When the visitor wants an app, follow the playbook above."
    HEAD = "  The persona (Alex McRitchie's own, public):"

    module_function

    # The rules, then the page, indented under them. `build` adds the /build rule.
    def block(repo_root:, build: false)
      rules = build ? "#{RULES}\n#{BUILD_RULE}" : RULES
      "#{rules}\n#{HEAD}\n#{cap(page(repo_root)).gsub(/^/, '  ')}"
    end

    # The printed part of the page: below its rule, HTML comments and blank
    # indented lines removed; FALLBACK when there is none. Read as UTF-8 whatever
    # the locale (launchd starts the dispatcher with no LANG).
    def page(repo_root)
      path = File.join(repo_root, DOC)
      doc = File.file?(path) ? File.read(path, encoding: "UTF-8").scrub.gsub(/<!--.*?-->/m, "") : ""
      text = doc.include?("\n---\n") ? doc.split("\n---\n", 2).last.gsub(/^[ \t]+\n/, "").gsub(/\n{3,}/, "\n\n").strip : ""
      text.empty? ? FALLBACK : text
    end

    def cap(text)
      text.length <= BUDGET ? text : text[0, BUDGET - CUT.length] + CUT
    end
  end
end
