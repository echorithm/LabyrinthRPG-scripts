extends RefCounted
class_name BootstrapVmap
##
## One-shot vmap creator/loader that mirrors the original pipeline.
## - If {seed}.vmap.json exists: load+validate(+backfill if needed) and return.
## - If missing: build → fill art → validate → persist → return.
## - Writes user://villages/active.seed as part of Provider flow.
##

static func ensure(
	seed: int,
	radius: int,
	catalog: BaseTileCatalog,
	paths: VillageMapPaths = null,
	schema: VillageMapSchema = null,
	builder: VillageMapSnapshotBuilder = null,
	resolver: TileArtResolver = null
) -> Dictionary:
	var r: int = max(1, radius)

	# Instantiate collaborators if not provided
	var _paths := (paths if paths != null else VillageMapPaths.new())
	var _schema := (schema if schema != null else VillageMapSchema.new())
	var _builder := (builder if builder != null else VillageMapSnapshotBuilder.new())
	var _resolver := (resolver if resolver != null else TileArtResolver.new())

	# Resolver needs a catalog (deterministic art fill). Do not proceed without one.
	_resolver.catalog = catalog

	# Build the canonical provider and let it do the heavy lifting.
	var provider := VillageMapProvider.new(_paths, _schema, _builder, _resolver)

	# Prefer existing on-disk snapshot; else build fresh. Provider handles both.
	var snap: Dictionary = provider.get_or_build(seed, r)

	# Provider guarantees: tiles mirrored in both views, render_key computed, file persisted.
	return snap
