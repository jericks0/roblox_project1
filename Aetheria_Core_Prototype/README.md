# Aetheria — Core Prototype v0.1

Starter scaffold for a Roblox fantasy MMORPG built with Luau, Roblox Studio, VS Code, Rojo, and Codex.

## Important
- This is a project scaffold, not a finished game.
- The world is intended to be one continuous Roblox place/server instance per public server.
- Roblox may run multiple copies of that same place for different groups of players.
- Character data is account-based and will contain multiple character slots.
- Death does not delete characters, inventory, or progression.

## Requirements
- Roblox Studio
- Visual Studio Code (or compatible editor)
- Rojo 7+
- Rojo plugin installed in Roblox Studio
- Git (recommended)

## First setup
1. Extract this folder.
2. Open the folder in VS Code.
3. Install Rojo using the current official Rojo installation instructions.
4. In a terminal in this folder, run `rojo serve`.
5. Open a new Baseplate experience in Roblox Studio.
6. Open the Rojo plugin and connect to the local Rojo server.
7. Press Play. The server output should show the Core bootstrap message.

Official Rojo guide: https://rojo.space/docs/
Roblox external tools guide: https://create.roblox.com/docs/projects/external-tools

## Codex first task
Ask Codex to read `docs/CORE_SPEC.md` and `docs/ARCHITECTURE.md` first.
Tell it to make small, reviewable changes and not invent new systems or change the data schema without updating the docs.

## Current status
- [x] Initial project structure
- [x] Rojo project mapping
- [x] Core bootstrap placeholder
- [ ] Profile loading and saving
- [ ] Multiple character slots
- [ ] Character selection UI
- [ ] Character creation
- [ ] Session-safe saving and error handling
