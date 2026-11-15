# Compliance

## Game tool rules (Grinding Gear Games)
This is our reading of GGG's long-standing third-party tool policy. Re-check the official wording before release.
- ✅ Reading item text the user copied with Ctrl+C.
- ✅ Reading the game's `Client.txt` log file.
- ✅ Drawing a separate always-on-top window over a windowed game.
- ✅ Sending **one** game action per user keypress (e.g., hotkey → one Ctrl+C, or one chat message).
- ❌ Reading or writing game memory, injecting into the process, hooking DirectX/Vulkan.
- ❌ Inspecting or modifying network traffic.
- ❌ Automating actions without a keypress per action (no macros, no auto-reply, no timers).

QA reviews every hotkey and every feature that sends input to the game against this list.

## Copyright / originality
PoE Overlay (Kyusung Interactive Co., Ltd.) is a feature reference only.
- ✅ Implementing similar *features* (price check, trade helper, etc.). Features aren't copyrightable.
- ❌ Copying their code, UI layout, screenshots, icons, text, or name/branding.
- Game item names and data come from official sources and are used only for their factual meaning.
- Not affiliated with or endorsed by Grinding Gear Games. State this in the README and the installer.
