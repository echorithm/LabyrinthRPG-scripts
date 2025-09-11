extends Resource
class_name WorldSegment

# Segment groups are 3 floors each: seg 1 = floors 1..3, seg 2 = 4..6, etc.
@export var segment_id: int = 1
@export var drained: bool = false              # prior segments get drained when you anchor ahead
@export var boss_sigil: bool = false           # last-known flag for that segment (live charge stays in Run)
