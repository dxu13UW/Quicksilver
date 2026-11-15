# ADR-003: Distribution (DRAFT)
**Status:** Proposed

**Plan**
A Windows installer published on GitHub Releases, containing:
- the Qt client plus its runtime
- a self-contained Elixir release (ERTS included, so users don't install Elixir)

**Requirement (added 2026-11-15)**
- Users install through a standard Windows setup wizard. See PLAN.md item F7 for the pages.

**To decide in Week 4**
- Installer tool (Inno Setup vs WiX)
- Packaging tool for the Elixir side (standard `mix release` vs a single-binary wrapper)
- Code-signing (likely skipped; document the SmartScreen warning)
