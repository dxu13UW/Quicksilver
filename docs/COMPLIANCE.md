# Compliance

## Game tool rules (Grinding Gear Games)
Checked against GGG's developer docs (https://www.pathofexile.com/developer/docs) on **2026-11-15**. Re-check before each release.

**What GGG's docs say (quoted where it matters)**
- Desktop apps that run separately from the game are *"permitted"*, though *"not encouraged"*.
- **Overlay rules** apply to apps that use the screen, the clipboard or the game's logs:
  - *"You may only read this information as long as the user is aware of what you are doing with that data."*
  - *"Reading from the screen or clipboard may only be performed once per manual key press."*
- **Macro rules** apply to any input that affects the game:
  - Macros *"must be invoked manually by the user"*. Not allowed: *"timers, reacting to file changes, or from reading the screen"*.
  - Each macro invocation has *"one set function"*.
  - It *"may only perform one action that interacts with the game (sending a single chat message or command counts as one action)"*.
- Apps that *"interact with the game or game files"* are strictly against the ToU (sections 7b, 7c, 7i).

**Our rules**
- ✅ Reading item text the user copied with Ctrl+C: one clipboard read per manual keypress.
- ✅ Reading the game's `Client.txt` log file. The README and the About screen tell the user that we do this, and why.
- ✅ Drawing a separate always-on-top window over a windowed game.
- ✅ Sending **one** game action per manual keypress or click (e.g. hotkey → one Ctrl+C, or quick-reply click → one chat message).
- ❌ Reading or writing game memory, injecting into the process, hooking DirectX/Vulkan, or modifying game files.
- ❌ Inspecting or modifying network traffic.
- ❌ Any game input triggered by anything other than a user keypress or click. That includes timers, a new line in `Client.txt` (e.g. auto-replying to a whisper), and screen reading.
- ❌ Cycling actions: one hotkey always does the same single thing.

QA reviews every hotkey and every feature that sends input to the game against this list.

## External APIs: accepted risk
- GGG's docs: *"We can only support resources defined in our API Reference… It is against our Terms of Use (section 7i) to reverse-engineer endpoints outside of this documentation."*
- The trade search, fetch and data endpoints we use are **not** in that reference.
- **Decision (ADR-004):** use them anyway, only for items poe.ninja can't price, on demand, within the header rate limits, and behind a kill switch. This is a known, accepted risk, in line with long-standing community tools.
- GGG restricts apps that make *"too many invalid requests"* (any HTTP 4xx, including 429). The clients must avoid errors, not only rate-limit breaks.

## Copyright / originality
PoE Overlay (Kyusung Interactive Co., Ltd.) is a feature reference only.
- ✅ Implementing similar *features* (price check, trade helper, etc.). Features aren't copyrightable.
- ❌ Copying their code, UI layout, screenshots, icons, text, or name/branding.
- Game item names and data come from official sources and are used only for their factual meaning.
- Don't use GGG's company or game logos in a way that looks official.

## Third-party notice
GGG requires public tools to show this statement in a visible place:

> This product isn't affiliated with or endorsed by Grinding Gear Games in any way.

It must appear in the README, the installer (PLAN F7) and the command center's About screen.
