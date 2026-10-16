module CtoReport
  # Each CTO's fixed template: the same facts, said the way that soul talks
  # (docs/agents/agents/<soul>/soul.md, and tyrion/voice.md). DETERMINISTIC:
  # strings with %{…} slots that CtoReport::Message fills from code. No model
  # call, so a line can never invent a number, hype a quiet day or name a
  # person. Keep each line plain and short; the facts carry the report.
  #
  # Slots: %{app} %{until} (the window end) · %{activity} ("3 signups and
  # 1 contact message") · %{problems} ("4 errors in 2 kinds") · %{reason} (why
  # the health report could not be read) · %{building} %{in_review}
  # %{deploying} %{shipped} %{release} (the hub's board, board: only).
  module Voice
    # The hub's board line, the same facts in every voice (only the hub has it).
    BOARD = "On the board: %{building} in build, %{in_review} waiting on review, %{deploying} on the way to " \
            "production, %{shipped} shipped in the window. %{release}".freeze

    VOICES = {
      # Avi: friendly, user-first, decisive; says what to look at.
      "avi" => {
        signature: "Avi",
        open: "Morning. Here is %{app} for the day to %{until}.",
        quiet: "A quiet day: no errors and nothing new.",
        activity: "%{activity}, and no errors. A good day for the people using it.",
        errors: "%{problems}. Worth a look before the next release goes out.",
        unreachable: "I could not read the health report (%{reason}), so I have no numbers for you today.",
        board: BOARD
      },
      # Turf: sports talk, but the box score is the facts and nothing more.
      "turf_monster" => {
        signature: "Turf",
        open: "Morning from the Turf Monster booth. Box score for the day to %{until}.",
        quiet: "Quiet field: no errors and no new activity.",
        activity: "%{activity}, and zero errors. Clean game.",
        errors: "%{problems}. Flag on the play; worth a review.",
        unreachable: "No feed from the app today (%{reason}), so no box score.",
        board: BOARD
      },
      # Tyrion: short, dry, warm underneath (tyrion/voice.md). Family-friendly.
      "tyrion" => {
        signature: "Tyrion",
        open: "%{app}'s ledger for the day to %{until}.",
        quiet: "A quiet day: no errors, no newcomers. Peace is underrated.",
        activity: "%{activity}, and not a single error. I would drink to that, modestly.",
        errors: "%{problems}. Debts like these compound if nobody looks.",
        unreachable: "The ravens brought nothing (%{reason}). No numbers today.",
        board: BOARD
      }
    }.freeze

    module_function

    def for(soul) = VOICES.fetch(soul.to_s) { raise KeyError, "no CTO voice for soul #{soul.inspect}: add one to CtoReport::Voice::VOICES" }
    def known?(soul) = VOICES.key?(soul.to_s)
  end
end
