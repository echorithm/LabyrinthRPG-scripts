extends RefCounted
class_name AnimAuto

# Always prefer this exact clip if present.
const PREFERRED_IDLE := "IdleNormal"

# Reasonable fallbacks if IdleNormal is missing.
const IDLE_CANDIDATES: PackedStringArray = [
	"Idle", "idle", "IDLE", "IdleLoop", "Idle_Loop", "Loop_Idle"
]

const PREFERRED_BATTLE := "IdleBattle"
const BATTLE_CANDIDATES: PackedStringArray = [
	"IdleBattle", "IdleNormal", "Idle"
]

static func play_idle(root: Node) -> bool:
	var ap := _find_animation_player(root)
	if ap == null:
		return false

	var name := _pick_idle_clip(ap)
	if name == StringName(""):
		return false

	# Ensure the idle actually loops.
	var anim := ap.get_animation(name)
	if anim != null and anim.loop_mode == Animation.LOOP_NONE:
		anim.loop_mode = Animation.LOOP_LINEAR

	ap.play(name)
	return true
	
static func play_battle_idle(root: Node, candidates: PackedStringArray = BATTLE_CANDIDATES) -> bool:
	# 1) Try AnimationPlayer (preferred path)
	var ap := _find_animation_player(root)
	if ap != null:
		var name := _pick_clip_from(ap, candidates)
		if name != StringName(""):
			var anim := ap.get_animation(name)
			if anim != null and anim.loop_mode == Animation.LOOP_NONE:
				anim.loop_mode = Animation.LOOP_LINEAR
			ap.play(name)
			return true

	# 2) Try AnimationTree (state machine) – travel to the first candidate
	var at := _find_animation_tree(root)
	if at != null:
		at.active = true
		var playback := at.get("parameters/playback") as AnimationNodeStateMachinePlayback
		if playback != null:
			for cand in candidates:
				playback.travel(String(cand)) # if state exists, it will switch; harmless otherwise
				return true

	return false

# --- helpers -------------------------------------------------

static func _find_animation_player(n: Node) -> AnimationPlayer:
	var q: Array[Node] = [n]
	while not q.is_empty():
		var cur: Node = q.pop_front()
		var ap: AnimationPlayer = cur as AnimationPlayer
		if ap != null:
			return ap
		for c: Node in cur.get_children():
			q.push_back(c)
	return null

static func _pick_idle_clip(ap: AnimationPlayer) -> StringName:
	# 1) Exact preferred name.
	if ap.has_animation(PREFERRED_IDLE):
		return StringName(PREFERRED_IDLE)

	# 2) Common idle names.
	for c in IDLE_CANDIDATES:
		if ap.has_animation(c):
			return StringName(c)

	# 3) Fuzzy: first clip containing "idle" (case-insensitive).
	for s in ap.get_animation_list():
		var sl := String(s)
		if sl.to_lower().contains("idle"):
			return StringName(sl)

	return StringName("")
	
static func _find_animation_tree(n: Node) -> AnimationTree:
	var q: Array[Node] = []
	q.append(n)
	while q.size() > 0:
		var cur := q.pop_front() as Node
		var at := cur as AnimationTree
		if at != null:
			return at
		for c_any in cur.get_children():
			var c := c_any as Node
			if c != null:
				q.append(c)
	return null

static func _pick_clip_from(ap: AnimationPlayer, candidates: PackedStringArray) -> StringName:
	# 1) exact candidates
	for c in candidates:
		if ap.has_animation(c):
			return StringName(c)
	# 2) fuzzy: first animation containing the first candidate token (e.g., "idlebattle"/"idle")
	if candidates.size() > 0:
		var token := String(candidates[0]).to_lower()
		for s in ap.get_animation_list():
			var sl := String(s)
			if sl.to_lower().contains(token):
				return StringName(sl)
	return StringName("")
