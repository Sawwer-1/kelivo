# Kelivo Phone Gateway（手机 adb 网关）

把一台安卓手机变成 Kelivo 桌面端的工具外设：**零改手机包**，全部能力走 adb
（USB 或无线 TCP）。桌面 agent 由此获得截屏、点按滑动、Shell、应用管理、
短信/通话记录读取、电量与设备信息等 16 个工具。

## 前置

1. Python 3.10+，装 MCP SDK（v1）：
   ```
   pip install "mcp<2"
   ```
2. adb：以下任一即可——
   - 环境变量 `ADB_PATH` 指向 adb.exe；
   - `adb` 已在 PATH；
   - 默认探测路径（`D:\dev\platform-tools\adb.exe`、
     `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`）。
3. 手机开启 USB 调试并授权；无线模式先 USB 连一次
   （工具 `phone_connect` 直连 `ip:5555`）。

## Kelivo 接入

设置 → MCP → 添加服务器，传输选 **stdio**：

```json
{
  "transport": "stdio",
  "command": "python",
  "args": ["D:/dev/aaa-desktop/kelivo/tools/phone_gateway/phone_gateway.py"],
  "env": {}
}
```

## 工具一览（16）

| 工具 | 用途 | 建议审批 |
|---|---|---|
| phone_list_devices | 列设备（型号/版本/状态） | 自动 |
| phone_device_info | 品牌/型号/安卓版本/分辨率 | 自动 |
| phone_battery | 电量/状态/温度 | 自动 |
| phone_read_sms / phone_read_call_log | 读短信/通话记录（条数上限 100） | 建议 ask |
| phone_screenshot | 截屏到主机临时目录，返回路径 | 自动 |
| phone_dump_ui | 窗口层级 XML（tap 坐标来源） | 自动 |
| phone_tap / phone_swipe | 点按/滑动（像素坐标） | 建议 ask |
| phone_input_text | 键入 ASCII 文本（空格转 %s） | 建议 ask |
| phone_key_event | BACK/HOME/POWER 等按键 | 建议 ask |
| phone_list_packages | 列应用（可过滤） | 自动 |
| phone_shell | 任意 shell 命令 | **ask** |
| phone_install / phone_uninstall | 装/卸应用 | **ask** |
| phone_connect | 无线 adb 直连 | 自动 |

## 冒烟测试

```
python tools/phone_gateway/smoke_test.py
```

应输出 `SMOKE_OK`、16 个工具名、设备列表；无设备时 `phone_battery`
返回带指引的错误（这是预期行为）。

## 已知边界

- `phone_input_text` 只支持 ASCII（`input text` 的系统限制）；中文输入需
  ADBKeyboard 类 IME 方案，后续版本再说。
- 多设备并存时，各工具用 `device` 参数传 serial（`phone_list_devices` 可查）。
- `phone_shell` 能做任何事（含读短信、删文件）——审批务必开。
- 截屏/UI dump 的临时文件在 `%TEMP%\kelivo_phone_gateway\`，可随时清理。
