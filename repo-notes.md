# LabyrinthRPG Scripts – Notes for Reviews

## Repo Facts
- **Private source of truth:** https://github.com/echorithm/LabyrinthRPG  
- **Public mirror (read-only):** https://github.com/echorithm/LabyrinthRPG-scripts  
- **Branch:** main  
- **Path mapping:**  
  - Private path `scripts/<subpath>` → Public path `<subpath>`  
  - Example: `scripts/dungeon/DungeonGenerator.gd` → `dungeon/DungeonGenerator.gd`

## Coding Rules
- Godot 4.4.1, GDScript only.  
- **Typed GDScript required**: no inferred `Variant`.  
- Typed arrays/dictionaries only.  
- `@onready` variables must be typed.  
- Use casting when calling `get_node()` or dynamic methods.  
- Stick to Godot 4.4.1 API surface; flag uncertainty if unsure.

## Allowed Helpers
- `TypedRead` helper (for safe typed property access).  

## Scene Stubs
- Example node path (common):  
  - `Dungeon/Player` → `CharacterBody2D`  
  - `Dungeon/EnemySpawner` → `Node2D`  

## Review Workflow
- When a path is given (e.g. `dungeon/DungeonGenerator.gd`), interpret relative to the **public mirror root**.  
- Output format must always be:  
  1. **Summary**  
  2. **PATCH (unified diff)**  
  3. **Repro/Verify** checklist  
  4. **Assumptions & Risks**

## Guardrails
- Never request or store tokens.  
- Do not propose changes requiring public assets.  
- Only generate patches; user applies them locally via:  
  ```bash
  git apply --index patch.diff
  git commit -m "fix: <message>"
  git push