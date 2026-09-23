require "test_helper"

# [unit] THE TRIPWIRE. `.env.example` is the fresh-machine template: a rebuild
# reads it to learn which 1Password item holds which secret, and in which vault.
# So a pointer here that names a RETIRED item, or a vault that no longer exists,
# sends the rebuild to a name that does not resolve — and the failure lands on
# the one day nobody has a working machine to debug it from.
#
# That is not hypothetical. `agent.higgesfield` was retired on 2026-09-20 and
# every prose doc was corrected in the same pass, but this file was left behind
# — deliberately, because `bin/dor-check` classifies a diff's shape by FILE and
# a comment-only `.env.example` edit disqualifies the `docs` shape. It was
# tracked as a follow-up and then nearly archived out from under the template.
# A census that depends on someone remembering is the thing this replaces.
#
# A POINTER IS A PAIR, and the first version of this guard compared only half of
# it. The originating defect had TWO halves: `.env.example` named an item that
# had been retired AND a vault (`agents`) that had been renamed to
# `studio-agents` on 2026-08-28. Had only the VAULT been wrong, the guard would
# not have caught its own bug. Measured 2026-09-22, it still had not: two live
# pointers still read "in agents vault", and `op vault list` returns no such
# vault. The vault clause is now compared too — against the register, and
# against the item's own row.
#
# THE INVENTORY SIDE HAD NO CONTROL, which is the failure mode this class is
# most exposed to: every assertion below is a SEARCH, and a search over an empty
# or mis-parsed corpus answers "nothing wrong" indistinguishably from a search
# over a clean one. Measured with the retired pointer restored, the old guard
# went green AND BLIND under three independent inventory reformats — a leading
# space on each row, the name cell losing its backticks, or a row marked RETIRED
# in its description rather than its name. The parse is now TABLE-AWARE and
# every table it reads carries a floor.
class EnvExampleCredentialPointersTest < ActiveSupport::TestCase
  TEMPLATE  = Rails.root.join(".env.example")
  INVENTORY = Rails.root.join("docs/agents/modules/credential-inventory.md")

  # `# 1Password: "<item>"`, plus the OPTIONAL vault clause the template writes
  # after it (`in studio-agents vault`). The vault group is optional because not
  # every pointer states one, and demanding it would red on pointers that are
  # merely terse rather than wrong.
  POINTER = /\#\s*1Password:\s*"([^"]+)"(?:\s+in\s+`?([A-Za-z0-9_.\-]+)`?\s+vault)?/

  # The two inventory tables this guard reads, keyed by their HEADER ROW rather
  # than by "a line that starts with a pipe". The inventory holds five tables;
  # the loose form scooped 42 rows out of all of them — the vault register, the
  # GitHub App id table, an HTTP-status table and a bucket table mixed in with
  # the 27 credential rows — so any count taken over it measured nothing in
  # particular and a "vault cell" could be an HTTP status.
  CREDENTIAL_TABLE = "| Item | Vault | Purpose | Typical consumer |"
  VAULT_TABLE      = "| Vault | Purpose |"

  # HOW THE INVENTORY MARKS AN ITEM THAT MUST NOT BE POINTED AT, read from the
  # NAME and VAULT cells only — never from the description.
  #
  # NOT THE WHOLE ROW, and that is load-bearing: the live
  # `higgsfield.studio.agents` row says "Supersedes agent.higgesfield", so a
  # row-wide match condemns the replacement along with the thing it replaced.
  #
  # THREE SPELLINGS, not one, because the name cell was only ever ONE of the
  # places deadness is recorded. Measured over the 27 credential rows
  # 2026-09-22: exactly one row is dead in its NAME (`agent.higgesfield
  # (RETIRED - ...)`) and two more are dead only in their VAULT cell —
  # `agent.github` at `— (deleted)` and `x.api` at "absent on 2026-08-29". Both
  # were invisible to the name-only reading, and `.env.example` was pointing at
  # one of them.
  DEAD = /RETIRED|DELETED|\babsent\b/i

  # --- controls ---------------------------------------------------------------

  test "the template is readable and actually carries pointers" do
    # Every assertion below is vacuously true against an empty match set, so a
    # regex that silently stopped matching would read as green.
    assert_operator pointers.length, :>=, 3,
                    "expected several `# 1Password: \"...\"` pointers in .env.example; " \
                    "found #{pointers.inspect} — the pointer format changed and this guard went blind"
  end

  test "the inventory tables parse, or every comparison below is vacuous" do
    assert_operator credential_rows.size, :>=, 20,
                    "parsed #{credential_rows.size} credential row(s) from #{CREDENTIAL_TABLE.inspect} " \
                    "in credential-inventory.md — too few to be the real register, so the pointer " \
                    "checks below are searching an empty corpus and passing for that reason"
    assert_operator declared_vaults.size, :>=, 5,
                    "parsed #{declared_vaults.size} vault(s) from #{VAULT_TABLE.inspect} — too few to " \
                    "be the real register; the vault check below would then accept any vault at all"
    assert_includes credential_rows.keys, "higgsfield.studio.agents",
                    "the parse must find a row it is known to contain — a floor alone does not prove " \
                    "the NAME cell is being read, only that some rows were counted"

    # AND EVERY ROW IS FOUR CELLS. This is what makes #cells load-bearing rather
    # than decorative: one live row spells a Squads permission set as
    # `Propose | Vote | Execute` inside a code span, so a naive String#split("|")
    # reads it as SIX cells. Nothing else here would notice — the stray pipes land
    # in the purpose cell, which no assertion reads — so without this the
    # backtick-aware splitter could be deleted and every test would stay green.
    ragged = table_rows(CREDENTIAL_TABLE).reject { |cells| cells.size == 4 }

    assert_empty ragged.map { |cells| [cells.size, cells.first] },
                 "every credential row is `| item | vault | purpose | consumer |`. A row that does " \
                 "not split into four cells is either malformed or carries an unescaped pipe the " \
                 "splitter did not respect, and its VAULT cell is then whatever landed in slot two."
  end

  # --- the pointer checks -----------------------------------------------------

  test "no pointer names a retired, deleted or absent inventory row" do
    dead = pointers.map(&:first).select { |item| dead_in_inventory?(item) }

    assert_empty dead,
                 "these .env.example pointers name items the credential inventory marks retired, " \
                 "deleted or absent: #{dead.inspect}. A fresh-machine rebuild reads this file — " \
                 "point it at the live item named in docs/agents/modules/credential-inventory.md."
  end

  # THE REGISTER MUST BE COMPLETE. An item the inventory has never heard of is
  # not "fine", it is UNAUDITABLE: this guard has nothing to compare it against
  # and passes it for that reason alone, which is the shape of every silent-green
  # failure above. Filing the row is cheap and is what makes the other checks
  # able to speak.
  test "every pointer is registered in the credential inventory" do
    unregistered = pointers.map(&:first).reject { |item| credential_rows.key?(item) }

    assert_empty unregistered,
                 "these .env.example pointers name items with no row in " \
                 "docs/agents/modules/credential-inventory.md: #{unregistered.inspect}. Until a row " \
                 "exists, nothing here can tell a live item from a retired one or a wrong vault from " \
                 "a right one. File the row — including one that records the item is NOT filed."
  end

  # --- the vault half ---------------------------------------------------------

  test "a pointer's vault clause names a vault the inventory declares" do
    undeclared = pointers.filter_map do |item, vault|
      "#{item} → #{vault}" if vault.present? && declared_vaults.exclude?(vault)
    end

    assert_empty undeclared,
                 "these .env.example pointers name a vault that is not in the inventory's vault " \
                 "register: #{undeclared.inspect}. Declared vaults are #{declared_vaults.to_a.sort.inspect}. " \
                 "`agents` was RENAMED to `studio-agents` on 2026-08-28 (same vault id); a rebuild " \
                 "told to look in `agents` finds no such vault."
    end

  test "a pointer's vault clause matches the vault its inventory row records" do
    mismatched = pointers.filter_map do |item, vault|
      row_vault = credential_rows.dig(item, :vault)
      next if vault.blank? || row_vault.blank? || row_vault == vault

      "#{item}: template says #{vault}, inventory says #{row_vault}"
    end

    assert_empty mismatched,
                 "the template and the inventory disagree about where these items live: " \
                 "#{mismatched.inspect}. One of the two is wrong and a rebuild trusts the template."
  end

  private

  def pointers
    @pointers ||= TEMPLATE.read.scan(POINTER).map { |item, vault| [item, vault.presence] }.uniq
  end

  # A row is dead when its own NAME or VAULT cell carries the marker. See DEAD.
  def dead_in_inventory?(item)
    row = credential_rows[item]
    return false if row.nil?

    row[:name_cell].match?(DEAD) || row[:vault_cell].match?(DEAD)
  end

  # { "<item>" => { name_cell:, vault_cell:, vault: } } for the credential table.
  # `vault` is the first backticked token of the vault cell, or nil when the cell
  # holds prose instead (`— (deleted)`).
  def credential_rows
    @credential_rows ||= table_rows(CREDENTIAL_TABLE).each_with_object({}) do |cells, acc|
      name_cell, vault_cell = cells[0].to_s, cells[1].to_s
      item = name_cell[/\A\s*`([^`]+)`/, 1]
      next if item.nil?

      acc[item] = { name_cell: name_cell, vault_cell: vault_cell, vault: vault_cell[/`([^`]+)`/, 1] }
    end
  end

  # Every vault name the register declares. A cell may name more than one — the
  # blockchain row reads "`Blockchain` / `🧱 Blockchain`" — so all backticked
  # tokens in the name cell count.
  def declared_vaults
    @declared_vaults ||= table_rows(VAULT_TABLE).flat_map { |cells| cells[0].to_s.scan(/`([^`]+)`/).flatten }.to_set
  end

  # The rows of the table whose header row is `header`, as cell arrays. The body
  # starts two lines after the header (the separator) and ends at the first line
  # that is not a table row.
  def table_rows(header)
    lines = INVENTORY.each_line.map(&:rstrip)
    start = lines.index { |line| line.strip == header }
    return [] if start.nil?

    lines[(start + 2)..].to_a.take_while { |line| line.start_with?("|") }.map { |line| cells(line) }
  end

  # SPLIT OUTSIDE BACKTICKS. One live row spells a Squads permission set as
  # `Propose | Vote | Execute` inside a code span, so String#split("|") reads that
  # row as six cells and hands back an execution permission where the vault
  # should be. Measured 2026-09-22: one of 27 rows, and it is the mainnet signing
  # key's — the row least safe to mis-read.
  def cells(line)
    parts = [+""]
    in_tick = false
    line.strip.each_char do |char|
      case char
      when "`" then in_tick = !in_tick; parts.last << char
      when "|" then in_tick ? parts.last << char : parts << +""
      else parts.last << char
      end
    end
    parts.map(&:strip).reject.with_index { |cell, i| cell.empty? && (i.zero? || i == parts.size - 1) }
  end
end
