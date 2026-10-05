# Kelivo Learning Gateway（外挂学习服务）

把 AAA「Learning Runtime」的精髓铸成桌面外挂：一个**独立进程+自有 SQLite**
的运营型长期记忆——记录「怎么做主公喜欢的事」（偏好/纠正/工作流教训），
与 Kelivo 原生记忆（记「主公是谁」的事实层）分工互补。

核心机制：**Shadow 影子期**。每条经验先入影子（`shadow`），不进召回、不进
导出；主公复审后 `learning_promote` 晋升才生效——防止模型一次幻觉把噪音
焊进长期行为。

## 前置

```
pip install "mcp<2"
```

## Kelivo 接入

设置 → MCP → 添加服务器，传输选 **stdio**：

```json
{
  "transport": "stdio",
  "command": "python",
  "args": ["D:/dev/aaa-desktop/kelivo/tools/learning_gateway/learning_gateway.py"],
  "env": {}
}
```

存储位置：`%APPDATA%\kelivo_learning\lessons.db`（可用环境变量
`LEARNING_DB` 重定向）。

## 工具一览（7）

| 工具 | 用途 |
|---|---|
| learning_record | 记一条经验（入影子期；同文去重） |
| learning_recall | 按关键词召回已晋升经验（带使用计数） |
| learning_review_queue | 列出待复审的影子经验 |
| learning_promote / learning_archive | 晋升 / 归档 |
| learning_stats | 按状态/类型统计 + 高频标签 |
| learning_export_worldbook | 已晋升经验导出为 Kelivo 世界书 JSON（一次导入常驻生效） |

## 让模型用起来的最小配法

给常用助手的系统提示词贴一段规约（按需裁剪）：

```
【学习规约】当用户纠正你的做法、明确表达偏好、或某工作流成败有成因时，
调用 learning_record 记录（type: preference|correction|workflow|fact|lesson，
tags 用逗号分隔的关键词）。接到非平凡任务前，先 learning_recall 查相关经验。
```

## 复审工作流

1. 对模型说「列出待复审的学习条目」（→ learning_review_queue）；
2. 逐条判断：可信赖 →「晋升第 N 条」；错误/过时 →「归档第 N 条」；
3. 想让经验常驻注入 →「把学习成果导出成世界书」（→ 导出 JSON →
   Kelivo 设置 → 世界书 → 导入）。

## 冒烟测试

```
python tools/learning_gateway/smoke_test.py
```

全生命周期自检（记录→去重→影子隔离→复审→晋升→召回→统计→导出），
应输出 `SMOKE_OK`。

## 已知边界

- 模型驱动式学习：依赖模型按规约调用，无对话旁路监听（Kelivo 无外部
  事件钩子，这是宿主架构边界）；
- 召回为关键词匹配（LIKE），无向量语义检索；
- 世界书导出为一次性快照，晋升新条目后需重新导出导入。
