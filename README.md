# dialspace — 用 Logi MX Creative Dialpad 大旋钮切换 macOS 桌面

Use the large dial on a Logitech MX Creative Dialpad to switch between macOS Spaces. The small dial and other input devices keep their normal behavior. Setup instructions follow in Chinese.

把 **Logitech MX Creative Dialpad** 的大旋钮转动，映射成 macOS 左右切换桌面 / Spaces——
带和 `Ctrl + ←/→` 一模一样的**原生横滑动画**，Dock / 菜单栏正确联动。

**与 Logi Options+ 完全共存**：Options+、Keypad 键盘模块、鼠标全程在线，本工具只"借用"大旋钮的横向滚动。

---

## 效果

| 操作 | 结果 |
|---|---|
| 转大旋钮（右/左） | 桌面带横滑动画切到右/左一个 Space |
| 转小旋钮 | 正常上下滚动（不受影响） |
| 鼠标 / 触控板 | 完全不受影响 |
| Logi Options+ / Keypad / LIFT | 全程正常工作 |

---

## 环境要求

- macOS（开发验证于 macOS 26 / Apple Silicon；其他版本和 Intel Mac 未验证）
- Xcode 命令行工具（`swiftc`）
- Logitech MX Creative Dialpad（蓝牙连接）+ Logi Options+ 正在运行
- 至少 2 个桌面 / Spaces

---

## 安装

### 1. Options+ 里配置大旋钮

打开 **Logi Options+ → MX Creative Dialpad → 旋钮和滚轮**，
把**大旋钮**功能设为 **「鼠标左右滑动 / 水平滚动」**。
（小旋钮可保留为上下滚动或任意功能，互不干扰。）

> 原理：Options+ 会把"左右滑动"实现成 `Shift + 滚动` 注入事件——这正是本工具识别大旋钮的专属签名。

### 2. 编译 + 安装 + 自启

```bash
git clone https://github.com/skyler176/dialspace.git
cd dialspace
make install
```

会：编译 → 拷贝到 `~/.local/bin/dialspace` → 写入 LaunchAgent → 加载并自启。

### 3. 授予「辅助功能」权限（关键，一次性）

launchd 启动的进程不继承终端权限，需要给二进制单独授权：

1. **系统设置 → 隐私与安全性 → 辅助功能**
2. 点 **`+`** → 在文件框按 `Cmd+Shift+G` → 输入 `/Users/<你>/.local/bin/dialspace` → 添加并**打开开关**
3. 服务会由 launchd 自动重试（也可执行 `make status` 查看状态）

### 4. 验证

```bash
make logs        # 看到「共存模式运行中…」即成功；转旋钮会打印 → 右滑/左滑切桌面
```

---

## 工作原理

整条链路分两段：**识别大旋钮** + **触发原生切换**。

### A. 识别大旋钮（CGEventTap）

Options+ 把大旋钮的"左右滑动"注入成系统滚动事件。本工具用 `CGEventTap` 监听滚动事件，
按三重签名锁定大旋钮，命中后**吞掉该事件**（避免窗口被横向滚动）并触发切桌面：

- 带 **Shift** 修饰键（小旋钮裸滚动，无 Shift）
- **离散**滚动（`IsContinuous == 0`；触控板/鼠标是连续滚动）
- 来源进程名含 **Logi**（避免误伤你手动 Shift+滚动）

### B. 触发原生切换（合成 DockSwipe 手势）

不模拟按键、不调瞬切 API，而是用 `CGEvent` 合成一组 **DockSwipe 手势事件**
（began → changed → ended），走 Dock 真实手势通道：

- **低 velocity（默认 5）= 带原生横滑动画**；调高趋向瞬切（iss 用 400 做无动画瞬切）
- Dock / 菜单栏 / 全屏空间行为全部正确联动
- **无需安装驱动、无需关闭 SIP**

> DockSwipe 事件构造配方参考 [joshuarli/iss](https://github.com/joshuarli/iss)。
> 这里使用了未公开的事件字段编号，属于依赖 macOS 内部实现的做法；系统更新后可能需要调整。源码中还保留了仅供实验的 SkyLight 私有接口，用于 `--diag`，日常 `--tap` 模式不调用它。

---

## 逆向过程中验证过、但行不通的路（避坑记录）

| 方案 | 结果 |
|---|---|
| IOHIDManager 直接读设备 HID 报文 | ❌ Logi agent 在跑时**独占设备**，旋钮的 HID++ 私有报文（`11 FF 0D …`）被它吃掉，系统侧收不到 |
| 在 Options+ 里把旋钮设成"滚动"、用 IOHIDManager 读 | ❌ Options+ 的滚动是**软件合成注入**，不从设备发 HID，读不到 |
| 合成 `Ctrl + ←/→` 按键（CGEvent） | ❌ macOS 26 对系统级热键做了**合成事件过滤**，按键漏进前台 App，不切空间 |
| `CGSInvokeSymbolicHotKey` 私有接口 | ❌ macOS 26 已**移除**该符号 |
| `SLSManagedDisplaySetCurrentSpace`（含事务版 + 动画标志） | ⚠️ 能切，但是**伪切换**：无动画，且 Dock/菜单栏不联动（全屏空间 Dock 不隐藏） |
| **合成 DockSwipe 手势** | ✅ **最终方案**：在开发环境中有原生动画和正确联动；依赖未公开事件字段 |

设备侧逆向数据：VID `0x046D` / PID `0xBC00`（Dialpad，BLE）；Keypad PID `0xC354`（USB）；
HID++ 4.5；旋钮旋转 = feature `0x0D`（byte[5] 有符号增量）；角键码 `0x53/56/59/5A`。

---

## 调参

源码 `dialspace.swift` 顶部：

| 变量 | 含义 | 默认 |
|---|---|---|
| `SWIPE_VEL` | 切换动画软硬；越低越柔，越高越脆/瞬切 | `5.0` |
| `STEP` | 累计多少滚动单位切一次（越大越钝） | `1` |
| `COOLDOWN` | 两次切换最小间隔，防快速旋转连切 | `0.30s` |

改完执行 `make reload`（**重编后 cdhash 变化，需重新授权辅助功能**）。

### 调试 / 排查模式

```bash
./dialspace --tap --debug      # 打印每个滚动事件(轴/来源PID/修饰键),用来核对大旋钮签名
./dialspace --swipe <vel>      # 右滑一次→左滑回来,试某个 velocity 的动画效果
./dialspace --diag             # 实验性 SkyLight 路径:来回切一次;不代表日常模式
```

---

## 常用命令

```bash
make status      # 查看服务状态
make logs        # 跟踪日志
make reload      # 改源码后重编 + 重启
make uninstall   # 停用并移除(日志保留)
```

---

## 自愈机制

守护进程内置自愈,以下情况会**自动恢复，无需手动干预**：

- 事件 tap 被系统超时禁用 → 回调里立即 `CGEventTapEnable` 重新启用
- 插拔显示器 / 分辨率变化 → 注册了 `CGDisplayReconfigurationCallback`，变化后重启 tap
- 兜底看门狗：每 3 秒检查一次 tap 是否还活着，停了就拉起

日志里出现 `⚠️ … 已自动重新启用 / 已自动重启` 即为自愈触发。

---

## 故障排查

**转旋钮不切屏了**（多见于插拔屏、睡眠唤醒后，理论上已被自愈覆盖，万一没好）：

```bash
launchctl kickstart -k gui/$(id -u)/com.skyler.dialspace   # 强制重启守护进程
make logs                                                  # 看是否回到「共存模式运行中…」
```

**日志反复刷 `❌ 创建事件 tap 失败`**：辅助功能权限没生效。注意——
**只要最后一行是 `共存模式运行中(含自愈看门狗)…` 就说明已正常**，前面的 `❌` 只是授权生效前的重试残留，可忽略。

**改完源码 `make reload` 后失效**（重要）：重新编译会改变二进制 cdhash，旧的辅助功能授权随即失效。
需到「系统设置 → 隐私与安全性 → 辅助功能」**先选中 `dialspace` 点 `−` 删除，再 `+` 重新添加**
`/Users/<你>/.local/bin/dialspace` 并打开开关（仅开关切换通常不够，必须删后重加）。不改源码则一劳永逸。

**多屏下只有焦点显示器能切**：DockSwipe 跟随焦点显示器（与原生 `Ctrl+←/→` 一致），
焦点所在屏若只有 1 个空间（如正开全屏 App）则无处可切，属正常现象。

---

## 文件清单

| 文件 | 说明 |
|---|---|
| `dialspace.swift` | 全部源码（单文件） |
| `Makefile` | 编译 / 安装 / 重载 / 卸载 |
| `com.skyler.dialspace.plist.in` | LaunchAgent 模板（`make install` 时填充路径生成） |
| `README.md` | 本文档 |
| `.gitignore` | 排除本机编译产物和日志 |
| `LICENSE` | MIT 许可证 |

---

## 卸载

```bash
make uninstall
```

并到「系统设置 → 隐私与安全性 → 辅助功能」移除 `dialspace` 条目即可。Logi Options+ 不受任何影响。
