# Next task: presentation before broad bug fixing

## Game

A 1–4 player cooperative office night-shift horror game. Players collect six hard drives from other desks, dock them at the corner workstation and sit down to open a retro desktop UI with varied deletion minigames. Random door, power, boss-message and trash-task disturbances interrupt work. Fair warning cues and counterplay must make escalating pressure survivable. Narrative progress builds toward a climax; events are not scheduled at fixed clock times. Use a fictional former employee for the pursuer story.

## User's current feedback

The office is too rugged, dirty and crowded. Props clip into one another, desks are overloaded and walls look neglected. The user wants a clean, believable office after hours: restrained, cozy and unsettling through quietness, fog, muted colors and localized warmth. The reference is Silent Hill 2's atmosphere, not blanket grime or industrial decay. Keep roughly 6–8 closely arranged desks with clear circulation and a corner workstation.

1. Remove unnecessary clutter and clipping. Keep furniture, door swings, chair access and interaction routes usable. Select a few purposeful props per desk and leave some empty surfaces. Do not place assets simply because they are supplied.
2. Replace dirty wall treatments with clean wallpaper or maintained painted walls and trim. Prefer clean furniture variants and subtle age. Keep the office cared for and occupied.
3. Use this palette with restraint:

| Use | Color |
|---|---|
| Outdoor fog | Pale blue-gray `#A8BAC3` |
| Cold ambient light | Slate blue-gray `#778B96` |
| Shadowed walls | Charcoal blue `#353F46` |
| Faded carpet and curtains | Dusty burgundy `#60494D` |
| Old plastic and painted trim | Muted cream `#B7B09C` |
| Popcorn cabinet lighting, if present | Soft amber `#C8A66B` |

Keep the cold fog primarily outside and near windows. Charcoal is a shadow tone, not the paint color for every wall. Use warm amber practical lighting in small areas. Maintain readable interiors; avoid excessive bloom, crushed blacks, saturated lighting and heavy indoor fog.

4. Lock gameplay to first person. Seated desktop use must release the mouse for UI input, then restore first-person control on exit. Avoid camera clipping through the head and nearby furniture.
5. Replace generic typography and default-looking text boxes. Use a consistent hierarchy, padding, alignment, borders and readable controls. The user likes [Silkscreen](https://create.roblox.com/store/asset/12187371840/Silkscreen), selectively for short retro computer labels, status text and keycaps. Use a complementary readable font for longer text and dialogue. Do not apply Silkscreen everywhere; verify the Roblox font actually works.
6. Style the desktop as a coherent older Windows-like interface with restrained cream/gray surfaces and clear window titles. Avoid oversized rounded mobile-style panels.
7. Replace the default visible E prompt with a custom prompt: a small E keycap and a specific nearby-target action label such as Collect drive, Dock drive or Sit down. Avoid overlapping prompts. The underlying ProximityPrompt system may remain, but its visible presentation should be custom.

## Workflow and evidence

Read `studio/export-manifest.json` and compare `studio/local-working-tree/` before editing. The preserved loose revision contains different clean asset choices, camera/UI changes and a PromptUi module that were not all present in the selected Studio game. Reconcile useful changes rather than overwriting them blindly. The main `src/` baseline was exported from the user-selected Studio session.

Revise layout/materials, then atmosphere, then first-person and UI presentation. Preserve gameplay and co-op authority rules. Build with Rojo and run appropriate static checks. Cloud execution has no live Studio MCP access: clearly distinguish headless/build checks from actual Studio playtesting. Provide the rebuilt place and a concise local testing checklist covering navigation, clipping, sitting/leaving the PC, mouse capture, E prompts and text legibility. Then proceed to the wider bug-fixing pass.
