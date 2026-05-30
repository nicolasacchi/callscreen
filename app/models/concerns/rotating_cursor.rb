# Atomic round-robin cursor over a list, backed by an integer column on the
# record. Shared by Tenant (voice/phrase rotation) and Contact (per-contact
# phrase rotation), and used by PhrasePoolResolver — collapsing the three
# copies of the with_lock { idx = col; pick; update_column } block (CQ-7).
module RotatingCursor
  extend ActiveSupport::Concern

  # Returns list[cursor % size] and advances the cursor column by one, under a
  # row lock so two concurrent webhooks can't pick the same index. Modulo by
  # (size * 1000) keeps the stored index bounded regardless of list size.
  def advance_rotation!(list, column:)
    return nil if list.empty?
    chosen = nil
    with_lock do
      idx = public_send(column) || 0
      chosen = list[idx % list.size]
      update_column(column, (idx + 1) % (list.size * 1_000))
    end
    chosen
  end
end
