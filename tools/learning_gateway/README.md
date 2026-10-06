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

## 工具一览（8）

| 工具 | 用途 |
|---|---|
| learning_record | 记一条经验（入影子期；同文去重） |
| learning_recall | 按内容召回已晋升经验（SQLite FTS5 全文：中文 bigram + 英数词元，bm25 排序；无 FTS5 自动回退 LIKE；带使用计数） |
| learning_review_queue | 列出待复审的影子经验 |
| learning_promote / learning_archive | 晋升 / 归档 |
| learning_stats | 按状态/类型统计 + 高频标签 |
| learning_export_worldbook | 已晋升经验导出为 Kelivo 世界书 JSON（一次导入常驻生效） |
| learning_ingest_inbox | 摄取对话旁路收件箱：把宿主落盘的完成轮次蒸馏为影子经验并归档源文件 |

## 对话旁路钩子（自动学习）

Kelivo 侧开关：**设置 → 显示 → 其他设置 → 对话旁路学习**（默认关闭）。

开启后，每次回复生成完成，宿主把该轮对话（用户消息 + 助手回复，均限长）
写成一个 JSON 文件落入收件箱：

```
%APPDATA%\kelivo_learning\inbox\bypass-<时间戳>-<随机>.json
{"ts": ..., "conversation_id": "...", "user_text": "...≤2000", "assistant_text": "...≤4000"}
```

`learning_ingest_inbox` 在 MCP 会话里调用即可消费收件箱：

- 用户消息含学习信号（纠正/偏好关键词）→ 蒸馏为一条影子经验
  （`source=inbox:<会话>`，confidence 0.45，等人复审）；
- 无信号 → 直接归档不产经验；
- 处理完的文件移入 `inbox/processed/`（解析失败进 `inbox/failed/`）。

该路径**不依赖模型配合**——即使模型从不调用 learning_record，旁路仍会
把可学习信号送进影子期。建议在系统提示词规约里加一句：会话开始时先调用
`learning_ingest_inbox`。

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

全生命周期自检（记录→去重→影子隔离→复审→晋升→召回→统计→**旁路摄取**→
**中文 FTS 召回**→导出），应输出 `SMOKE_OK`。

## 已知边界

- 影子期人审兜底：旁路与模型记录都先入影子，杜绝未审经验直接生效；
- 召回为 FTS5 全文（bigram 词元匹配），无向量语义检索（嵌入模型选型后再议）；
- 世界书导出为一次性快照，晋升新条目后需重新导出导入。
