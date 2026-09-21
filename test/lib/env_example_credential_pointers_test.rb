require "test_helper"

# [unit] THE TRIPWIRE. `.env.example` is the fresh-machine template: a rebuild
# reads it to learn which 1Password item holds which secret. So a pointer here
# that names a RETIRED item sends the rebuild to a name that no longer resolves,
# and the failure lands on the one day nobody has a working machine to debug it
# from.
#
# That is not hypothetical. `agent.higgesfield` was retired on 2026-09-20 and
# every prose doc was corrected in the same pass, but this file was left behind
# — deliberately, because `bin/dor-check` classifies a diff's shape by FILE and
# a comment-only `.env.example` edit disqualifies the `docs` shape. It was
# tracked as a follow-up and then nearly archived out from under the template.
# A census that depends on someone remembering is the thing this replaces.
#
# WHAT IT CANNOT SEE, stated plainly: an item the inventory does not list at all.
# `anthropic` and `🐊 TikTok` are named here and appear in no inventory row, so
# this guard has nothing to compare them against and passes them. The register
# is the inventory; a pointer to something outside it is a different gap, and
# widening this test to demand a row for every pointer would fail today on two
# credentials this change is not about.
class EnvExampleCredentialPointersTest < ActiveSupport::TestCase
  TEMPLATE  = Rails.root.join(".env.example")
  INVENTORY = Rails.root.join("docs/agents/modules/credential-inventory.md")

  # `# 1Password: "<item>"` — the one pointer form the template uses.
  POINTER = /#\s*1Password:\s*"([^"]+)"/

  # How the inventory marks a row that must not be pointed at any more. Both
  # spellings are in use: an item superseded by a rename, and one deleted outright.
  DEAD = /RETIRED|DELETED/i

  test "the template is readable and actually carries pointers" do
    # The control. Every assertion below is vacuously true against an empty
    # match set, so a regex that silently stops matching would read as green.
    assert_operator pointers.length, :>=, 3,
                    "expected several `# 1Password: \"...\"` pointers in .env.example; " \
                    "found #{pointers.inspect} — the pointer format changed and this guard went blind"
  end

  test "no pointer names a retired or deleted 1Password item" do
    dead = pointers.select { |item| dead_in_inventory?(item) }

    assert_empty dead,
                 "these .env.example pointers name items the credential inventory marks retired or " \
                 "deleted: #{dead.inspect}. A fresh-machine rebuild reads this file — point it at the " \
                 "live item named in docs/agents/modules/credential-inventory.md."
  end

  private

  def pointers
    @pointers ||= TEMPLATE.read.scan(POINTER).flatten.uniq
  end

  # The inventory rows lead with the item in backticks. A row is dead when its
  # OWN name carries the marker (`agent.higgesfield (RETIRED - use ...)`), not
  # when the row merely mentions one in prose — the live `higgsfield.studio.agents`
  # row says "Supersedes agent.higgesfield", and keying on the whole row would
  # condemn the replacement along with the thing it replaced.
  def dead_in_inventory?(item)
    INVENTORY.each_line.any? do |line|
      next false unless line.start_with?("| `")

      name = line[/\A\|\s*`([^`]+)`/, 1]
      name.present? && name.start_with?(item) && name.match?(DEAD)
    end
  end
end
