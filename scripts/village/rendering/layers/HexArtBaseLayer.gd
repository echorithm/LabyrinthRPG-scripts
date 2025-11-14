extends TileMapLayer
class_name HexArtBaseLayer

@export var debug_logging: bool = false

func ensure_tileset(ts: TileSet) -> void:
	tile_set = ts
	if debug_logging:
		print("[BaseLayer] tileset set. sources=", ts.get_source_count())

func paint(qr: Vector2i, source_id: int) -> void:
	if tile_set == null:
		return
	set_cell(qr, source_id, Vector2i.ZERO)

func clear_all() -> void:
	clear()
