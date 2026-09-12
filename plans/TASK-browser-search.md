# TASK: Browser name filter (search, 1.0 batch 1)

- Status: pending Plan Card / PROMPT (new session)
- Created: 2026-09-12
- Roadmap: plans/ROADMAP-1.0.md A3

## Goal
Filter the current directory listing by name, client-side, zero network
cost. Covers shares and the vault alike (same browser pipeline).

## Scope sketch
- NSSearchField in the browser toolbar (or ⌘F focuses it); typing
  filters the *already listed* items by name (case/diacritic-insensitive
  contains; pure filter function unit-testable).
- Filter is per-directory, cleared on navigation (path change) and on
  destination switch; result count + "no matches" empty state (reuse
  T1 空态配方, DESIGN-TOKENS §6.1).
- Out of scope: recursive/full-library search, content search, indexes.

## DoD (draft)
1. Pure filter fn covered by tests (empty query, case/diacritics, CJK).
2. Typing filters live; clearing restores; navigation resets.
3. Shares + vault both work offline-correct (no listing refetch).
4. 真机: ⌘F → 输入即过滤 → 无匹配空态 → 清空恢复。

## Risks
- Toolbar real estate in the browser (breadcrumb + search coexistence);
  decide icon-collapsible vs persistent field at Plan Card time.
