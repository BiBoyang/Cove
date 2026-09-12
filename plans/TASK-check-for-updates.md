# TASK: Check for updates (1.0 batch 1)

- Status: pending Plan Card / PROMPT (new session)
- Created: 2026-09-12
- Roadmap: plans/ROADMAP-1.0.md B6

## Goal
「检查更新…」entry (app menu + Settings) → query GitHub Releases for
the latest tag → compare with the running MARKETING_VERSION → alert:
already latest / new version available → open the release page.

## Scope sketch
- Zero new dependencies: URLSession GET api.github.com/repos/BiBoyang/
  Cove/releases/latest (public, no auth, no user data — privacy note in
  README if shipped).
- Semver compare as a pure function (v-prefix tolerant) + tests.
- Offline/error → quiet informational alert, never a crash path.
- Out of scope: Sparkle/auto-download, background periodic checks
  (decide at Plan Card whether a silent daily check is wanted).

## DoD (draft)
1. Pure semver compare tests (equal/older/newer/prerelease vs release).
2. Menu entry + Settings button both wired; alert copy 中文。
3. 真机: 当前版本 0.7.0 查询应得「已是最新」或列出新版（视当时
   latest）——两态至少验一态 + 模拟旧版本验「有新版」。

## Risks
- api.github.com rate limit (60/h unauthenticated) — single manual
  query is far below; note it.
- Network entitlement already present for SMB; https egress fine.
