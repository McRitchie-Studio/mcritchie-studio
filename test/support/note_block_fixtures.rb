# The shapes a model writes a notes section in, each with the reply that may be
# posted and the facts that must be read. One list, read by the worker's split
# (AgentMailbox::NoteBlock) AND the board's cut (AgentMessage.without_notes and
# complete!), so the two sides are held to the same cases.
module NoteBlockFixtures
  # [ answer text, reply posted, facts read ]
  CASES = [
    [ "Purple it is.\n===NOTES===\n[\"Favorite color is purple.\"]", "Purple it is.", [ "Favorite color is purple." ] ],
    [ "Ok.\n  ===NOTES===  \n```json\n[\"A\", \"B\", \"C\", \"D\"]\n```", "Ok.", %w[A B C] ],
    [ "Ok.\n===NOTES===\n{\"facts\": [\"X\", 7]}", "Ok.", [ "X" ] ],
    [ "Ok.\n===NOTES===\nnot json, with a secret", "Ok.", [] ],
    [ "  No notes here.\n", "No notes here.", [] ],
    # Inline, mid-sentence.
    [ "Got it! ===NOTES=== [\"Favorite color is purple.\"]", "Got it!", [ "Favorite color is purple." ] ],
    # Bold, italic, heading, spaced, lowercased, colon, two "=".
    [ "Noted.\n**===NOTES===**\n[\"Runs the hub.\"]", "Noted.", [ "Runs the hub." ] ],
    [ "Noted.\n_===NOTES===_ [\"Runs the hub.\"]", "Noted.", [ "Runs the hub." ] ],
    [ "Noted.\n### === NOTES ===\n[\"Runs the hub.\"]", "Noted.", [ "Runs the hub." ] ],
    [ "Noted.\n=== notes ===\n[\"Runs the hub.\"]", "Noted.", [ "Runs the hub." ] ],
    [ "Noted.\n===Notes:===\n[\"Runs the hub.\"]", "Noted.", [ "Runs the hub." ] ],
    [ "Noted. ==NOTES== [\"Runs the hub.\"]", "Noted.", [ "Runs the hub." ] ],
    [ "Noted.\n===NOTES\n[\"Runs the hub.\"]", "Noted.", [ "Runs the hub." ] ],
    # Inside a code fence: the fence opener does not dangle.
    [ "Noted.\n```\n===NOTES===\n[\"Runs the hub.\"]\n```", "Noted.", [ "Runs the hub." ] ],
    # Cut from the FIRST marker; a second one rides in the cut section.
    [ "One.\n===NOTES===\n[\"A fact.\"]\n===NOTES===\n[\"B\"]", "One.", [] ],
    # No delimiter at all, but a notes heading and a JSON array end the reply.
    [ "Noted.\n\n**Notes:**\n[\"Runs the hub.\"]", "Noted.", [ "Runs the hub." ] ],
    [ "Noted.\n## NOTES\n```json\n[\"Runs the hub.\"]\n```\n", "Noted.", [ "Runs the hub." ] ],
    # Not notes: prose that mentions notes, and an array that is the answer.
    [ "The release notes are out.", "The release notes are out.", [] ],
    [ "Here are the tasks:\n[\"a\", \"b\"]", "Here are the tasks:\n[\"a\", \"b\"]", [] ],
    [ "Notes: see the doc.", "Notes: see the doc.", [] ],
    # Code in an answer is not a marker: an operand before the "=".
    [ "Check `if count == notes.size` first.", "Check `if count == notes.size` first.", [] ],
    [ "In JS, a === notes.length is false.", "In JS, a === notes.length is false.", [] ]
  ].freeze
end
