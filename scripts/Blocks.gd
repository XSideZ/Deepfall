extends Node
## Autoload singleton: the single source of truth for block types and how they look.
## Adding a new block type = add an id const + a COLORS row + a NAMES row, and (if it
## should be placeable) add it to HOTBAR. A texture atlas can replace COLORS later
## without touching the mesher (UVs are already emitted).

const AIR := 0
const GRASS := 1
const DIRT := 2
const STONE := 3
const SAND := 4
const WOOD := 5
const LEAVES := 6
const BRICK := 7
const SNOW := 8
const COBBLE := 9
const PLANK := 10
const WATER := 11

# Per-block base colour, used as vertex colour until real textures are wired in.
const COLORS := {
	GRASS: Color(0.36, 0.65, 0.27),
	DIRT: Color(0.45, 0.32, 0.20),
	STONE: Color(0.50, 0.50, 0.52),
	SAND: Color(0.85, 0.78, 0.52),
	WOOD: Color(0.40, 0.28, 0.15),
	LEAVES: Color(0.20, 0.52, 0.18),
	BRICK: Color(0.62, 0.26, 0.22),
	SNOW: Color(0.93, 0.95, 0.98),
	COBBLE: Color(0.42, 0.42, 0.45),
	PLANK: Color(0.72, 0.56, 0.34),
	WATER: Color(0.24, 0.44, 0.82),
}

const NAMES := {
	GRASS: "Grass", DIRT: "Dirt", STONE: "Stone", SAND: "Sand",
	WOOD: "Wood", LEAVES: "Leaves", BRICK: "Brick", SNOW: "Snow",
	COBBLE: "Cobble", PLANK: "Plank", WATER: "Water",
}

# Placeable blocks shown in the hotbar, in slot order (slots 1..9).
const HOTBAR := [GRASS, DIRT, STONE, SAND, WOOD, LEAVES, BRICK, SNOW, COBBLE]


func is_solid(id: int) -> bool:
	return id != AIR


func color_for(id: int) -> Color:
	return COLORS.get(id, Color.WHITE)


func name_for(id: int) -> String:
	return NAMES.get(id, "?")
