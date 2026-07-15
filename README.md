# PersonalDataWipe

> Windows 个人数据彻底擦除工具 —— 换电脑 / 退租 / 二手出售前的最后一道防线。

一个 PowerShell 脚本，内置 21 个清理模块，按"从简单到困难"的顺序统一执行，覆盖系统缓存、浏览器密码、通讯软件、密码管理器、版本控制凭证、开发工具 token、微软账户、DPAPI 主密钥、WSL 发行版等几乎所有常见个人数据载体。所有操作均有实时进度显示与完整日志记录，并内置**测试模式**供先扫描后删除的安全验证。

- **作者**: Lendo527
- **版本**: v6.0
- **发布日期**: 2026-07-02
- **适用系统**: Windows 10 / Windows 11
- **PowerShell**: 5.1+（Windows 内置，无需安装额外运行时）

---

## 目录

- [为什么需要这个工具](#为什么需要这个工具)
- [功能特性](#功能特性)
- [21 个清理模块](#21-个清理模块)
- [使用方法](#使用方法)
- [测试模式（强烈推荐先用）](#测试模式强烈推荐先用)
- [执行流程与输出示例](#执行流程与输出示例)
- [日志位置](#日志位置)
- [注意事项与风险提示](#注意事项与风险提示)
- [常见问题](#常见问题)
- [技术实现](#技术实现)
- [许可证](#许可证)

---

## 为什么需要这个工具

当你更换电脑、退租、或将电脑转手他人时，仅"重装系统"或"格式化 C 盘"并不能真正清除你的个人数据：

- 浏览器保存的密码 / 自动填充 / Cookie
- 微信 / QQ / Telegram 等通讯软件的本地聊天缓存
- Git / SVN 的明文凭证与缓存的 SSH 私钥
- VSCode / Docker / AWS CLI 的 cloud token
- 微软账户的 DPAPI 主密钥（即使重装系统仍可解密旧凭据）
- WSL 发行版内的 `.ssh`、`.aws/credentials`、`.git-credentials`
- Navicat / DBeaver 等数据库连接配置（含明文或弱加密密码）
- Steam / Epic / Unity 等游戏与创意软件的登录态
- 系统的 Recent / Jumplist / 剪贴板历史

**PersonalDataWipe** 把上述所有"看似删了其实没删干净"的位置一次性扫光，配合 DPAPI 主密钥销毁，让本机残留凭据即使被恢复也无法解密。

---

## 功能特性

- **21 个模块统一执行**，无需手动勾选，一次跑完
- **从简单到困难排序**：先清缓存类（失败风险低），最后处理微软账户（涉及系统级凭据）
- **实时进度显示**：`[当前步/总步数] Mxx - 模块名 (XX%)` 全局百分比
- **每操作计数**：`[#0001] [DEL/TEST/SKIP] 路径` 让你看到每一次删除动作
- **每模块统计**：耗时 + 增量删除数 + 失败数 + ETA 预测剩余时间
- **Ctrl+C 优雅退出**：自动关闭 `Start-Transcript` 日志，不留半截文件
- **测试模式（TestMode）**：`$env:WIPE_TEST_MODE='1'` 仅扫描报告，绝对不删除任何文件
- **3 次重试删除**：被占用的文件会自动重试，提高成功率
- **COM 对象清理**：`Shell.Application` 等对象使用 `finally` 块释放，避免泄漏
- **管理员权限校验**：实际清理模式必须以管理员运行，否则直接退出
- **完整日志**：所有输出写入桌面 `PersonalDataWipe_*.log`，方便事后核查

---

## 21 个清理模块

模块按执行顺序排列（从简单到困难）：

| # | 模块 ID | 模块名称 | 覆盖内容 |
|---|---------|---------|---------|
| 1 | M01 | 临时文件与缓存 | `%TEMP%`、INetCache、ThumbCache、IconCache |
| 2 | M02 | 回收站清空 | 所有盘符 `$Recycle.Bin`，跳过 desktop.ini |
| 3 | M03 | 系统使用痕迹 | Recent / Jumplist / AutomaticDestinations / 剪贴板历史 / INetCache |
| 4 | M04 | 命令行历史与 PROFILE | PSReadLine `ConsoleHost_history.txt`、CMD doskey、PowerShell PROFILE |
| 5 | M05 | 下载工具配置 | IDM、迅雷、BitTorrent、qBittorrent、uTorrent 配置与历史 |
| 6 | M06 | 截图与搜索工具历史 | Snipaste、ShareX、Everything、Listary |
| 7 | M07 | 浏览器数据（含密码） | Edge / Chrome / Firefox / Brave / Opera：Cookie、Login Data、History、Web Data |
| 8 | M08 | 通讯软件 | QQ / 微信 / Telegram / Discord / 钉钉 / 飞书 本地缓存与登录态 |
| 9 | M09 | 邮件客户端 | Thunderbird / Foxmail / 网易邮箱大师 账户与邮件缓存 |
| 10 | M10 | 网盘客户端 | 百度网盘 / 坚果云 / Dropbox / 阿里云盘 / OneDrive token |
| 11 | M11 | 远程会议与录屏 | Zoom / Teams / 腾讯会议 / OBS 录制历史与账户 |
| 12 | M12 | 笔记与知识库 | Obsidian / Notion / 印象笔记 / 为知笔记 本地数据库 |
| 13 | M13 | 密码管理器 | Sticky Password / 1Password / Bitwarden / KeePass 本地保险库 |
| 14 | M14 | 数据库工具 | Navicat / DBeaver / SSMS / MySQL Workbench 连接配置（含密码） |
| 15 | M15 | 远程连接 | SSH `known_hosts`、PuTTY sessions / WinSCP / TeamViewer / FileZilla |
| 16 | M16 | 游戏与创意软件 | Unity 账户 / Steam `ssfn*` + `loginusers.vdf` / Epic / Adobe / Figma |
| 17 | M17 | 网络隧道工具 | OpenVPN / WireGuard / Clash / V2Ray 配置与节点 |
| 18 | M18 | 版本控制凭证 | Git `.git-credentials` / SVN auth cache / Mercurial |
| 19 | M19 | 开发工具 token | VSCode / Visual Studio / Docker / AWS / GCP / Azure / VM / Android SDK / Rust / Helm / Terraform / Maven / Conda / Postman |
| 20 | M20 | 微软账户 + 凭据管理器 + DPAPI + 系统日志 | **终极模块**：微软账户注销、Windows 凭据管理器、DPAPI Master Key（不可逆）、事件日志、PowerShell 操作日志 |
| 21 | M21 | WSL 发行版内个人数据 | 通过 `wsl.exe` 枚举所有发行版，删除 `~/.ssh`、`~/.aws`、`~/.git-credentials`、`~/.bash_history`、`~/.zsh_history` 等 |

---

## 使用方法

### 1. 下载脚本

```powershell
git clone https://github.com/Lendo527/PersonalDataWipe.git
cd PersonalDataWipe
```

或直接下载 [`PersonalDataWipe.ps1`](./PersonalDataWipe.ps1) 单文件。

### 2. 设置 PowerShell 执行策略（首次运行必读）

PowerShell 默认执行策略为 `Restricted`，会阻止本地未签名脚本运行，运行时会提示"无法加载，因为在此系统上禁止运行脚本"或"没有数字签名"。

以管理员身份打开 PowerShell，执行一次以下命令即可永久放行本地脚本：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

- `RemoteSigned` = 本地脚本可直接运行，从网络下载的脚本仍需数字签名
- `-Scope CurrentUser` 仅影响当前用户，无需改动全局策略
- 此命令只需执行一次，以后永久生效

执行后会提示确认，输入 `Y` 即可。之后可直接运行 `.\PersonalDataWipe.ps1`。

> 说明：本脚本为个人工具，未购买代码签名证书。`RemoteSigned` 是 Windows 官方推荐的本地开发策略，安全性与可用性平衡较好。

#### 已设了 RemoteSigned 还是提示"未数字签名"？

从网络（GitHub、邮件、网盘等）下载的文件会被 Windows 打上"来自互联网"的标记（Mark of the Web）。`RemoteSigned` 策略要求**带此标记的文件必须有签名**，所以即使设了策略仍会被拦。执行以下命令解除标记（只需一次）：

```powershell
Unblock-File .\PersonalDataWipe.ps1
```

之后即可正常运行 `.\PersonalDataWipe.ps1`。也可以在文件资源管理器里右键 → 属性 → 勾选"解除锁定"。

如果 `Unblock-File` 后仍报错，可能是公司组策略（GPO）覆盖了用户设置。运行 `Get-ExecutionPolicy -List` 查看，若 `MachinePolicy`/`UserPolicy` 为 `AllSigned`/`Restricted` 则无法修改，此时只能临时绕过：

```powershell
powershell -ExecutionPolicy Bypass -File .\PersonalDataWipe.ps1
```

### 3. 以管理员身份运行 PowerShell

> 实际清理模式必须管理员权限，否则脚本会直接退出。

- 右键开始菜单 → "Windows PowerShell (管理员)" 或 "终端 (管理员)"
- `cd` 到脚本所在目录

### 4. （强烈推荐）先用测试模式扫描

```powershell
$env:WIPE_TEST_MODE='1'
.\PersonalDataWipe.ps1
```

测试模式会：
- 跳过管理员权限检查
- 跳过 Y/N 确认
- 对每个会删除的目标只输出 `[TEST][FOUND] 路径`
- **绝对不删除任何文件**

### 5. 执行真实清理

```powershell
.\PersonalDataWipe.ps1
```

输入 `Y` 确认后开始执行。所有模块按顺序自动运行，无需干预。

### 6. 执行完毕

- 查看桌面日志 `PersonalDataWipe_<时间戳>.log`
- 建议重启电脑后再次以测试模式跑一遍，确认无残留

---

## 测试模式（强烈推荐先用）

测试模式由环境变量 `WIPE_TEST_MODE` 触发，**绝对安全**：

```powershell
# 启用测试模式
$env:WIPE_TEST_MODE='1'

# 运行
.\PersonalDataWipe.ps1

# 关闭测试模式（恢复实际清理）
Remove-Item Env:\WIPE_TEST_MODE
```

测试模式下的输出示例：

```
[#0001] [TEST][FOUND] C:\Users\xxx\AppData\Local\Temp\pub
[#0002] [TEST][FOUND] C:\Users\xxx\AppData\Local\Temp\trae-agent-toolhost
[#0003] [TEST][REGFOUND] HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery
```

每一行 `TEST][FOUND]` 都表示"如果实际清理，这里会被删除"。你可以借此核对范围是否符合预期。

---

## 执行流程与输出示例

启动时显示：

```
========================================
  PersonalDataWipe
  作者: Lendo527  |  版本: v6.0  |  日期: 2026-07-02
========================================

========== 清理步骤（共 21 项，按从简单到困难顺序）==========
   1. M01 - 临时文件与缓存（Temp/ThumbCache）
   2. M02 - 回收站清空
   ...
  21. M21 - WSL 发行版内个人数据（.ssh/.aws/git-credentials/history）

📌 执行时会显示实时进度：[当前步/总步数] Mxx - 模块名 (XX%)
📌 每个操作显示序号：[#0001] [DEL/TEST/SKIP] 路径

确认执行以上全部清理？(Y/N)
```

执行中：

```
============================================
  [7/21] M07 - 浏览器数据（Edge/Chrome/Firefox 含密码）  (33%)
============================================
[M07] 清理浏览器数据...
  [#0142] [DEL] C:\Users\xxx\AppData\Local\Microsoft\Edge\User Data\Default\Cookies
  [#0143] [DEL] C:\Users\xxx\AppData\Local\Microsoft\Edge\User Data\Default\Login Data
  [#0144] [SKIP] 路径不存在: C:\Users\xxx\AppData\Local\BraveSoftware
[M07] 完成
  模块耗时 1.2s | 增量: 删18 失败0 跳过5
  预计剩余: 8s（共 21 步，已完成 7 步）
```

执行结束输出整体统计：

```
========== 清理完成 ==========
  总删除: 523  失败: 7  跳过: 89
  总耗时: 42.5s
  错误详情见日志: C:\Users\xxx\Desktop\PersonalDataWipe_20260702_103045.log
```

---

## 日志位置

每次运行都会在**当前用户桌面**生成一个时间戳日志：

```
C:\Users\<你的用户名>\Desktop\PersonalDataWipe_<yyyyMMdd_HHmmss>.log
```

日志通过 PowerShell 的 `Start-Transcript` 写入，包含：
- 完整的命令输出
- 每一次删除/跳过/失败记录
- 模块耗时统计
- 错误堆栈

即使 Ctrl+C 中断，也会通过事件钩子优雅关闭日志，不会留下半截文件。

---

## 注意事项与风险提示

### 不可逆操作

- **M20 模块会销毁 DPAPI 主密钥**：意味着即使有人恢复了硬盘上的旧凭据文件，也无法解密。**这是本工具的核心价值，但确实不可逆。**
- 所有浏览器保存的密码、Cookie 一旦删除无法恢复（除非有云同步备份）
- 微软账户会从本机注销，需要重新登录

### 建议备份

执行前请确认以下数据已备份：
- 浏览器书签（如果未开启云同步）
- KeePass / 1Password 等本地保险库文件（`.kdbx`、`.opvault`）
- Git 仓库本身（`.gitconfig` 中的用户名邮箱可以再填，但本地未推送的 commit 会丢失）
- WSL 发行版内未推送的代码
- 微信 / QQ 的本地聊天记录（如果未开启同步）

### 不要在生产环境随意跑

- 不要在共享主机 / 公司办公电脑上跑（除非是 IT 流程的正式退役步骤）
- 不要在跑着关键服务的服务器上跑
- 建议在"个人电脑换机 / 二手出售"场景使用

### 关于 Steam

M16 会清除 Steam 的 `ssfn*` 文件与 `loginusers.vdf`，下次打开 Steam 需要重新登录，但**不会**卸载 Steam 本身或删除游戏库。

---

## 常见问题

### Q: 运行时提示"无法加载脚本，因为在此系统上禁止运行脚本"或"没有数字签名"？

A: 分两步处理：

1. 设置执行策略（一次永久生效）：`Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`
2. 如果是下载来的文件，还需解除网络下载标记：`Unblock-File .\PersonalDataWipe.ps1`

详见上文"使用方法 → 步骤 2"。

### Q: 跑完之后某些软件还在自动登录？

A: 部分软件会把 token 写入注册表的 `Run` 键或服务里，本工具主要清用户数据目录，不会动可执行文件与服务。建议执行后**重启一次电脑**再验证。如果仍有自动登录，手动登出一次即可。

### Q: 某些文件显示 `[FAIL]` 删除失败？

A: 通常是文件被占用。脚本会自动重试 3 次。如果仍失败，日志会记录具体路径。建议：
1. 关闭所有正在运行的程序
2. 重启电脑
3. 再次运行脚本

### Q: 可以选择只跑某些模块吗？

A: 当前版本为统一执行所有 21 个模块（按"全清"理念设计）。如果只想跑某几个模块，可以编辑脚本最后的执行循环，注释掉不需要的模块函数调用。

### Q: 会不会删除系统文件导致 Windows 崩溃？

A: 不会。脚本只清理**用户数据目录**与**特定注册表键**，不会动 `C:\Windows`、`C:\Program Files` 等系统目录。`$Recycle.Bin` 清理时会跳过 `desktop.ini` 等系统保护文件。

### Q: WSL 里的数据怎么处理？

A: M21 会通过 `wsl.exe --list --quiet` 枚举所有发行版（包括 docker-desktop 这类隐藏发行版），然后在每个发行版内执行 `rm -rf` 删除 `~/.ssh`、`~/.aws`、`~/.git-credentials`、`~/.bash_history` 等。**不会**卸载发行版本身，也不会动用户的代码仓库。

### Q: 跑完之后还能用电脑吗？

A: 可以正常使用。所有清理都是针对"个人数据"，不影响系统功能。只是各种软件下次打开需要重新登录。

---

## 技术实现

### 文件编码

脚本使用 **UTF-8 with BOM** 编码保存，确保中文注释在所有 PowerShell 版本下正确显示。

### 安全删除辅助函数

- `Remove-PathSafe`：3 次重试的删除函数，带测试模式判断
- `Remove-PathWildcard`：通配符删除（用于 `ssfn*` 等模式）
- `Remove-RegistryKey`：注册表键安全删除
- `Stop-ProcessAndWait`：500ms 轮询等待进程退出

### 进度统计

每模块开始时记录时间戳，结束时计算耗时与增量删除数，并基于已完成模块数预测 ETA。

### Ctrl+C 处理

通过 `Register-EngineEvent` 监听 `PowerShell.Exiting`，以及 `Register-ObjectEvent` 监听 `[Console]::CancelKeyPress`，确保中断时调用 `Stop-Transcript` 关闭日志。

### WSL 字符编码处理

`wsl.exe --list --quiet` 的输出是 UTF-16LE，脚本会去除 NULL 字符与 BOM 标记，正确解析发行版名称（避免出现 `U b u n t u` 这种带空格的错误解析）。

### COM 对象释放

`Shell.Application` 等 COM 对象在 `finally` 块中通过 `[System.Runtime.InteropServices.Marshal]::ReleaseComObject` 释放，避免内存泄漏。

---

## 许可证

本项目采用 [MIT License](./LICENSE)。

你可以自由使用、修改、分发本脚本，但作者不对使用后果承担任何责任。**请务必先在测试模式下核对范围，确认无误后再实际执行。**

---

## 更新日志

详见 [VERSION](./VERSION) 文件中的版本历史注释，每个版本的变更说明都记录在其中。

---

## 反馈与贡献

- Issue: [提交问题](https://github.com/Lendo527/PersonalDataWipe/issues)
- PR: 欢迎补充新的清理模块或修复已知问题

如果你发现了某个软件的残留数据没被清理，欢迎在 Issue 中提供软件名称与数据位置，我会补充到对应模块。
