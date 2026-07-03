# With You

一个 Godot 4.7 制作中的 2D 像素沙盒生活原型。玩家会和一个由 OpenAI 兼容格式 LLM 驱动的 AI 玩家一起生活、探索、行动、记忆和发展世界。

当前版本重点在底层系统：世界生成、玩家和 AI 实体、AI 感知与行动、LLM 调用、记忆 CSV 存储、存档、角色素材和基础 UI。建筑、NPC、采集、战斗、生产等玩法还没有完整实现。

## 当前功能

- 2D 顶视角像素沙盒地图。
- 中心 `99 x 99` 城区范围，外围由噪声生成草地、平地和河流。
- 玩家可移动，可选择三种初始属性/技能预设。
- AI 玩家可由 LLM 驱动，也支持未配置 LLM 时的本地占位回复。
- AI 支持 mood、发言、记忆、跟随状态和基础行动。
- AI 可执行移动、寻路、搜索地形、游荡、临时跟随玩家等行动。
- AI 行动事件会重新触发感知，例如找到目标地形、搜索失败、行动完成。
- AI 发言显示为屏幕上方横向消息框，左侧显示当前 mood 头像。
- 支持新建存档、读取存档、随时保存、退出前询问是否保存。
- 每个存档独立保存世界、时间、玩家、AI、角色信息和 AI 记忆。
- AI 最近记忆、历史记忆、元数据使用 CSV 存储，便于直接查看。
- 方块贴图和角色贴图支持外部 png 素材优先，缺失时回退到代码绘制或纯色。

## 运行环境

- Godot `4.7 stable`
- 项目渲染器：`GL Compatibility`
- 当前项目主场景：`res://scenes/main.tscn`
- 当前默认分辨率：`1920 x 1080`

可以用 Godot 编辑器打开项目目录：

```text
D:\Code\GDScript\with-you.exe
```

也可以用命令行启动：

```powershell
& "D:\Desktop\Godot_v4.7-stable_win64.exe" --path "D:\Code\GDScript\with-you.exe"
```

无窗口启动检查：

```powershell
& "D:\Desktop\Godot_v4.7-stable_win64.exe" --headless --path "D:\Code\GDScript\with-you.exe" --quit-after 2
```

## 基本操作

- `WASD` 或方向键：移动玩家。
- `Enter`：聚焦底部聊天输入框。
- 输入文字后按 `Enter` 或点击发送：主动与 AI 交流。
- `Ctrl + S`：保存当前存档。
- `Esc`：请求退出，游戏会询问是否保存。
- 开始界面可选择启动分辨率、新建存档或读取存档。

底部聊天框主要显示玩家输入和系统/debug 信息。AI 正式发言显示在屏幕上方弹出的横向对话框里。

## 项目结构

```text
assets/
  characters/
    inkbai/
      portraits/              # 墨白 mood 头像
      sprites/                 # 墨白移动小人 sprite sheet
  tiles/
    terrain/
      default/                 # 默认地形贴图

config/
  ai_prompt.json               # 默认 AI 角色提示词
  ai_prompt.example.json
  llm_config.json              # 本地 LLM 配置，已被 .gitignore 忽略
  llm_config.example.json

scenes/
  main.tscn                    # 主场景

scripts/
  ai/                          # AI 调度和记忆库
  config/                      # 全局参数
  core/                        # 时间、存档、路径、运行时 API
  entities/                    # 玩家和 AI 实体
  profiles/                    # 玩家预设和 AI 角色加载
  services/                    # LLM HTTP 客户端
  ui/                          # HUD、开始菜单、聊天框
  visual/                      # 像素小人和头像绘制/贴图
  world/                       # 地图生成和渲染

user_data/
  settings.json                # 本地设置，例如分辨率
  roles/                       # 自定义 AI 角色 JSON
  saves/                       # 存档目录
```

## 重要参数位置

主要参数在 [scripts/config/game_config.gd](scripts/config/game_config.gd)：

```gdscript
const TILE_SIZE = 16
const CITY_SIZE = 99
const START_GAME_MINUTES = 8.0 * 60.0
const GAME_MINUTES_PER_REAL_SECOND = 1.0

const PLAYER_SPEED = 96.0
const AI_SPEED = 78.0
const CAMERA_ZOOM = Vector2(2.5, 2.5)

const PERCEPTION_INTERVAL_GAME_MINUTES = 60.0
const RECENT_HISTORY_LIMIT = 12
const MEMORY_RECALL_COUNT = 8
const FORGET_INTERVAL_GAME_MINUTES = 60.0
const FORGET_PERCENT = 0.01
```

可用 mood：

```gdscript
["calm", "happy", "curious", "worried", "tired", "angry", "disappointed", "sad", "annoyed", "afraid"]
```

启动分辨率选项也在 `game_config.gd` 的 `RESOLUTION_OPTIONS` 中。玩家在开始界面选择后会保存到：

```text
user_data/settings.json
```

## LLM 配置

LLM 接口遵循 OpenAI Chat Completions 兼容格式：

```text
POST {api_base_url}/chat/completions
```

配置文件位置：

```text
config/llm_config.json
```

示例文件：

```text
config/llm_config.example.json
```

示例配置：

```json
{
  "api_base_url": "https://api.openai.com/v1",
  "api_key": "YOUR_OPENAI_COMPATIBLE_API_KEY",
  "model": "gpt-4.1-mini",
  "compression_model": "gpt-4.1-mini",
  "timeout_seconds": 120,
  "max_retries": 2,
  "retry_delay_seconds": 2
}
```

也可以使用环境变量覆盖：

```text
WITHYOU_LLM_API_BASE
WITHYOU_LLM_API_KEY
WITHYOU_LLM_MODEL
WITHYOU_LLM_COMPRESS_MODEL
WITHYOU_LLM_TIMEOUT_SECONDS
WITHYOU_LLM_MAX_RETRIES
WITHYOU_LLM_RETRY_DELAY_SECONDS
```

注意：`config/llm_config.json` 可能包含真实密钥，已经在 `.gitignore` 中忽略。不要把真实 API key 写进 README、提交记录或公开仓库。

如果没有配置 API key，游戏会使用本地离线占位 AI。占位 AI 可以回应玩家，但不会真正具备 LLM 推理能力。

## AI 系统

AI 调度入口：

```text
scripts/ai/ai_director.gd
```

AI 每次感知会构造一个快照，包含：

- 激活来源：玩家主动输入、自动感知、AI 行动事件。
- 玩家输入队列。
- AI 行动事件。
- 玩家附近地图编码。
- 玩家和 AI 当前状态。
- 游戏时间和现实系统时间。
- 最近压缩历史。
- 召回的历史记忆。
- 运行时 API 快照。

AI 需要返回 JSON。核心字段包括：

```json
{
  "talk_to_player": true,
  "dialogue": "要说的话",
  "has_action": true,
  "action": {},
  "set_follow": -1,
  "mood": "calm",
  "thought": "内部思考",
  "memory_ops": {
    "add": [],
    "update_priority": [],
    "delete": []
  }
}
```

`set_follow` 含义：

```text
-1 = 不改变跟随状态
 0 = 关闭持续跟随
 1 = 开启持续跟随
```

默认跟随状态是关闭。

### 激活来源

AI 会区分三种来源：

```text
player_interaction   玩家主动输入
auto_perception      自动实时状态感知
ai_action_event      AI 自己的行动结果
```

玩家主动输入时通常应该回复玩家。自动感知时通常不说话，除非发现重要情况、危险、任务结果或值得提醒玩家的变化。AI 行动事件通常只在找到目标、失败或完成任务时回复。

### 支持的 AI 行动

```json
{"type": "move_to_tile", "tile": [x, y]}
```

直接移动到指定地图格。

```json
{"type": "path_to_tile", "tile": [x, y], "avoid": ["water"]}
```

寻路到指定格，可避开指定地形。

```json
{
  "type": "search_for_tile",
  "target": "water",
  "scan_radius": 10,
  "max_steps": 24,
  "step_tiles": 8,
  "avoid": []
}
```

持续行走和扫描，直到找到某种地形或步数耗尽。支持目标：

```text
water
grass
plain
city
city_border
```

```json
{"type": "wander", "radius": 16, "steps": 8, "step_tiles": 8, "avoid": ["water"]}
```

在附近随机探索。

```json
{"type": "follow_player"}
```

执行一次移动到玩家附近的位置，不等同于持续跟随。

```json
{"type": "idle"}
```

停止当前行动。

## AI 记忆系统

记忆逻辑在：

```text
scripts/ai/ai_memory_store.gd
```

每个存档有独立记忆目录：

```text
user_data/saves/<save_id>/memory/
```

文件：

```text
ai_memory_recent.csv   最近压缩交互/思考记录
ai_memory_history.csv  历史记忆记录
ai_memory_meta.csv     元数据，例如 next_id
```

最近记录上限由：

```gdscript
GameConfig.RECENT_HISTORY_LIMIT
```

控制，当前默认 `12` 条。

历史记忆字段：

```text
id
priority
created_game_minutes
last_seen_game_minutes
source
summary
```

记忆优先级范围为 `1..9`，数字越大越重要。定期遗忘会删除优先级最低且更久远的部分记忆，比例由：

```gdscript
GameConfig.FORGET_PERCENT
```

控制。

## 存档系统

存档逻辑在：

```text
scripts/core/save_manager.gd
```

存档目录：

```text
user_data/saves/<save_id>/
```

每个存档包含：

```text
save.json
memory/
  ai_memory_recent.csv
  ai_memory_history.csv
  ai_memory_meta.csv
```

`save.json` 保存：

- 世界 seed。
- 游戏时钟。
- 玩家 profile、属性、技能、位置、朝向。
- AI profile、属性、技能、mood、位置、朝向、跟随状态、当前行动和行动队列。
- 当前 AI 角色和提示词。
- AI director 状态。

程序优先把用户数据保存到项目/程序目录下的：

```text
user_data/
```

如果该目录不可写，则回退到 Godot 的 `user://` 目录下。

## 世界和方块

世界生成：

```text
scripts/world/world_generator.gd
```

世界渲染：

```text
scripts/world/world_renderer.gd
```

当前方块类型：

```text
city
city_border
grass
plain
water
```

地图编码：

```text
C = city
B = city_border
G = grass
P = plain
W = water
```

中心城区范围是 `99 x 99`，边界为 `city_border`。城区外先生成河流，再使用噪声生成 `plain` 和 `grass`。

### 地形贴图

地形贴图优先读取：

```text
assets/tiles/terrain/default/
```

按方块类型同名匹配：

```text
city.png
city_border.png
grass.png
plain.png
water.png
```

也支持：

```text
webp
jpg
jpeg
```

如果某个方块没有贴图，会回退到原来的颜色绘制。

## 角色和素材

默认 AI 角色是墨白。角色定义主要来自：

```text
config/ai_prompt.json
scripts/profiles/ai_role_library.gd
scripts/profiles/character_profiles.gd
```

### AI 头像

AI 头像优先读取：

```text
assets/characters/inkbai/portraits/
```

按 mood 同名匹配：

```text
calm.png
happy.png
curious.png
worried.png
tired.png
angry.png
disappointed.png
sad.png
annoyed.png
afraid.png
```

如果某个 mood 没有图片，会优先使用 `calm.png`。如果 `calm.png` 也不存在，则回退到代码绘制头像。

当前 UI 中两处会使用该头像：

- 左上角状态栏 AI 小头像。
- 屏幕上方 AI 发言消息框大头像。

### AI 移动小人

默认墨白移动贴图：

```text
assets/characters/inkbai/sprites/inkbai-move.png
```

当前默认配置：

```gdscript
{
  "columns": 12,
  "rows": 1,
  "frames_per_direction": 3,
  "fps": 6.0,
  "idle_frame": 0,
  "walk_sequence": "2131",
  "frame_width": 55,
  "draw_size": [27, 41],
  "bottom_y": 12.0,
  "direction_frames": {"down": 0, "right": 3, "left": 6, "up": 9}
}
```

含义：

- 整张图是一条横向序列。
- 每个方向连续 3 帧。
- `down` 使用第 `0..2` 帧。
- `right` 使用第 `3..5` 帧。
- `left` 使用第 `6..8` 帧。
- `up` 使用第 `9..11` 帧。
- 静止时使用每组第 1 张，也就是 `idle_frame = 0`。
- 运动时按 `2 -> 1 -> 3 -> 1` 循环，对应配置字符串 `walk_sequence = "2131"`。
- `draw_size` 是世界中显示尺寸。
- `bottom_y` 控制脚底相对角色原点的位置。

当前默认墨白贴图配置在两个文件里仍有重复：

```text
scripts/profiles/ai_role_library.gd
scripts/entities/ai_companion.gd
```

一个用于新建角色 profile，一个用于旧存档或 profile 缺失时兜底。后续可以整理为公共配置，避免改漏。

## 自定义 AI 角色

可以在：

```text
user_data/roles/
```

放置自定义角色 JSON。开始界面新建存档时会自动加载这些角色作为选项。

示例结构：

```json
{
  "id": "custom_role_id",
  "name": "角色名",
  "description": "角色简介",
  "prompt": {
    "character_name": "角色名",
    "role": "角色定位",
    "background": "角色背景",
    "personality": ["性格1", "性格2"],
    "speaking_style": "说话风格",
    "relationship_to_player": "与玩家关系",
    "extra_system_prompt": "额外规则"
  },
  "profile": {
    "attributes": {"health": 100, "energy": 100, "hunger": 10, "focus": 70},
    "skills": [
      {"id": "conversation", "name": "交流", "level": 1}
    ],
    "sprite_sheet": {
      "path": "res://assets/characters/inkbai/sprites/inkbai-move.png",
      "columns": 12,
      "rows": 1,
      "frames_per_direction": 3,
      "fps": 6.0,
      "idle_frame": 0,
      "walk_sequence": "2131",
      "frame_width": 55,
      "draw_size": [27, 41],
      "bottom_y": 12.0,
      "direction_frames": {"down": 0, "right": 3, "left": 6, "up": 9}
    }
  }
}
```

没有提供的 prompt 字段会从 `config/ai_prompt.json` 补齐。

## 玩家预设

玩家初始预设在：

```text
scripts/profiles/character_profiles.gd
```

当前三种：

- `定居者`：体力稳定，适合生活建造。初始技能：采集、烹饪、建造。
- `探索者`：移动轻快，适合看图和发现资源。初始技能：寻路、涉水、追踪。
- `工匠`：专注较高，适合工具、武器和技能组合。初始技能：制造、维修、改造。

## UI 说明

HUD 逻辑在：

```text
scripts/ui/hud.gd
```

界面区域：

- 顶部状态栏：玩家/AI 头像、时间、LLM 状态、属性、AI mood、跟随状态、保存和退出按钮。
- 顶部 AI 消息框：AI 正式发言时出现，左侧 mood 头像，右侧文本。点击消息框可关闭。
- 底部聊天框：玩家输入、系统消息和 debug 信息。
- 开始菜单：分辨率、新建存档、读取存档、选择 AI 角色和玩家初始预设。

## 常见修改点

改游戏参数：

```text
scripts/config/game_config.gd
```

改 AI 默认提示词/人设：

```text
config/ai_prompt.json
```

改 LLM 接口：

```text
config/llm_config.json
```

改 AI 行动协议：

```text
scripts/ai/ai_director.gd
```

改 AI 移动、跟随、搜索、寻路：

```text
scripts/entities/ai_companion.gd
```

改玩家移动：

```text
scripts/entities/player.gd
```

改地图生成：

```text
scripts/world/world_generator.gd
```

改地图绘制和方块贴图：

```text
scripts/world/world_renderer.gd
```

改 AI/玩家像素小人绘制或 sprite sheet 切帧：

```text
scripts/visual/pixel_actor_view.gd
```

改头像图片读取和回退：

```text
scripts/visual/portrait_view.gd
```

改存档：

```text
scripts/core/save_manager.gd
```

改本地用户数据路径：

```text
scripts/core/app_paths.gd
```

改记忆 CSV 格式：

```text
scripts/ai/ai_memory_store.gd
```

## 开发注意事项

- `config/llm_config.json` 不要提交真实 API key。
- `user_data/saves/` 是运行时存档和记忆数据，可能会频繁变化。
- Godot 会生成 `.import` 和 `.godot/` 文件，`.godot/` 已被忽略。
- 图片素材建议保持像素风，导入后纹理过滤使用 nearest，避免模糊。
- 当前 AI 只感知玩家附近编码区域，不是全图全知。
- 当前实体碰撞和地形阻挡还比较基础，后续如果加入建筑/水域阻挡，需要扩展 collision 或路径规则。
- 当前 custom role 的头像目录还没有完全按角色 profile 动态切换，默认 UI 头像目录仍指向墨白素材。

## 后续可做

- 把默认墨白 sprite sheet 配置提取到公共配置，消除重复。
- 让不同 AI 角色拥有独立 portrait_dir、sprite_sheet、技能和武器外观。
- 增加资源、采集、背包、建造、烹饪等生活玩法。
- 让 AI 真正操作资源和设施，而不只是移动与记忆。
- 扩展地形：森林、沙地、石地、湿地、道路、建筑地块等。
- 为水域、建筑、障碍物接入更完整的碰撞和寻路成本。
- 给记忆系统加 UI 查看器和可编辑工具。
- 给 LLM 请求队列加可视化状态和重试控制。
