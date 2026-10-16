# The shapes a model writes a PROPOSAL section in, each with the reply that may
# be posted, the notes read, and the proposal parsed. One list, read by the
# worker's split (AgentMailbox::ProposalBlock) AND the board's cut
# (AgentMessage#complete!), so the two sides are held to the same cases.
module ProposalBlockFixtures
  ASK = { "kind" => "ask", "capability" => "board_status", "params" => {}, "summary" => "Count the board" }.freeze
  JSON_ASK = '{"kind": "ask", "capability": "board_status", "params": {}, "summary": "Count the board"}'.freeze

  # [ answer text, reply posted, notes read, proposal parsed ]
  CASES = [
    [ "I can count it.\n===PROPOSAL===\n#{JSON_ASK}", "I can count it.", [], ASK ],
    [ "I can count it.\n===PROPOSAL===\n```json\n#{JSON_ASK}\n```", "I can count it.", [], ASK ],
    # Inline, bold, spaced, lowercased, two "=".
    [ "Sure! ===PROPOSAL=== #{JSON_ASK}", "Sure!", [], ASK ],
    [ "Sure.\n**===PROPOSAL===**\n#{JSON_ASK}", "Sure.", [], ASK ],
    [ "Sure.\n=== proposal ===\n#{JSON_ASK}", "Sure.", [], ASK ],
    [ "Sure. ==PROPOSAL== #{JSON_ASK}", "Sure.", [], ASK ],
    # Inside a code fence: the opener does not dangle.
    [ "Sure.\n```\n===PROPOSAL===\n#{JSON_ASK}\n```", "Sure.", [], ASK ],
    # Broken JSON: cut anyway, nothing parsed.
    [ "Sure.\n===PROPOSAL===\n{not json, a secret", "Sure.", [], nil ],
    # Not an object.
    [ "Sure.\n===PROPOSAL===\n[\"a\"]", "Sure.", [], nil ],
    # Headed tail, no delimiter.
    [ "Sure.\n\n**Proposal:**\n#{JSON_ASK}", "Sure.", [], ASK ],
    # Notes first, then the proposal; and the other way round.
    [ "Purple.\n===NOTES===\n[\"Likes purple.\"]\n===PROPOSAL===\n#{JSON_ASK}", "Purple.", [ "Likes purple." ], ASK ],
    [ "Purple.\n===PROPOSAL===\n#{JSON_ASK}\n===NOTES===\n[\"Likes purple.\"]", "Purple.", [ "Likes purple." ], ASK ],
    # Not a proposal: prose that mentions one, and code.
    [ "The proposal is in the doc.", "The proposal is in the doc.", [], nil ],
    [ "Check `if a == proposal.id` first.", "Check `if a == proposal.id` first.", [], nil ]
  ].freeze
end
