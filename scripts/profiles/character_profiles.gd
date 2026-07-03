class_name CharacterProfiles
extends RefCounted


static func player_presets() -> Array:
	return [
		{
			"id": "settler",
			"name": "定居者",
			"description": "体力稳定，适合生活建造。",
			"attributes": {"health": 100, "energy": 90, "hunger": 12, "focus": 55},
			"skills": [
				{"id": "foraging", "name": "采集", "level": 1},
				{"id": "cooking", "name": "烹饪", "level": 1},
				{"id": "building", "name": "建造", "level": 1},
			],
		},
		{
			"id": "explorer",
			"name": "探索者",
			"description": "移动轻快，适合看图和发现资源。",
			"attributes": {"health": 90, "energy": 110, "hunger": 16, "focus": 60},
			"skills": [
				{"id": "pathfinding", "name": "寻路", "level": 1},
				{"id": "swimming", "name": "涉水", "level": 1},
				{"id": "tracking", "name": "追踪", "level": 1},
			],
		},
		{
			"id": "artisan",
			"name": "工匠",
			"description": "专注较高，适合工具、武器和技能组合。",
			"attributes": {"health": 95, "energy": 85, "hunger": 14, "focus": 75},
			"skills": [
				{"id": "crafting", "name": "制造", "level": 1},
				{"id": "repairing", "name": "维修", "level": 1},
				{"id": "enchanting", "name": "改造", "level": 1},
			],
		},
	]


static func ai_default() -> Dictionary:
	return {
		"id": "companion_ai",
		"name": "悠",
		"description": "由大模型驱动的共同生活 AI 玩家。",
		"attributes": {"health": 100, "energy": 100, "hunger": 10, "focus": 70},
		"skills": [
			{"id": "conversation", "name": "交流", "level": 1},
			{"id": "planning", "name": "规划", "level": 1},
			{"id": "companionship", "name": "陪伴", "level": 1},
		],
	}
