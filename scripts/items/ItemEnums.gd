# res://scripts/items/ItemEnums.gd
enum ItemType { WEAPON, ARMOR, JEWELRY }
enum WeaponFamily { SWORD, SPEAR, MACE, BOW }
enum ArmorArchetype { MAGE, LIGHT, HEAVY }
enum Rarity { COMMON, UNCOMMON, RARE, EPIC, ANCIENT, LEGENDARY, MYTHIC }

# Weapons route to these "family slots"; armor/jewelry use body slots.
enum EquipSlot { HEAD, CHEST, LEGS, BOOTS, SWORD, SPEAR, MACE, BOW, RING1, RING2, AMULET }

# Note:
# Affix slot counts are centralized in AffixRegistry.rarity_affix_count_for(item_type, rarity_code).
# This file intentionally contains no helper for counts to avoid drift.
