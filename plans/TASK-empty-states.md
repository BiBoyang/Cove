# TASK: Empty & loading states sweep (T1 remainder, 1.0 batch 1)

- Status: pending Plan Card / PROMPT (new session)
- Created: 2026-09-12
- Roadmap: plans/ROADMAP-1.0.md C7; evidence plans/UI-AUDIT-2026-09-05.md §T1

## Goal
Kill the remaining "naked" waiting/empty surfaces (audit T1 — the
biggest systematic gap): every wait has a spinner or skeleton, every
empty surface has guidance. Recipes already exist in
design/DESIGN-TOKENS.md §6.1/§6.2 — this card applies, not invents.

## Remainder list (audit-verified 2026-09-12)
1. Share grid loading: static icon + text → spinner (§6.2).
2. Empty folder: blank pane → 空态（图标+「此文件夹为空」）。
3. Directory switch: old listing lingers until new arrives → loading
   state (cleared listing + spinner).
4. Paged reader loading: black screen + bare page number → 占位配方。
5. Strip reader: "加载中" and "解码失败" share one placeholder → split.
6. Connect failure: placeholder "双击重试" + modal alert double prompt
   → converge to one (placeholder owns it, precedent: enumeration
   failure placeholder).

## DoD (draft)
1. Each surface follows §6.1/§6.2 recipes; no new ad-hoc placeholders.
2. Design decisions (if any new token) registered in DESIGN-TOKENS.
3. 真机前后对比截图（DoD 硬性，audit 规矩）。

## Risks
- Item 3 touches browser loading pipeline (generation guard interplay);
  item 6 changes an established alert flow — keep wording identical.
