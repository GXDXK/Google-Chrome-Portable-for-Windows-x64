# Chrome 便携版更新器

检查并更新 **Google Chrome 便携版** 与 **Chrome++ Next 增强插件**，显示两者的版本号。仅需 `ChromePlusUpdater.bat` + `ChromePlusUpdater.ps1` 两个文件即可完成全部构建与更新（Tool 中的工具缺失时会自动下载）。

## 本项目由 AI 完成

本项目使用 Codex + DeepSeek-V4-Flash-0731 完成项目编写。

## 使用方式

双击 `ChromePlusUpdater.vbs` 或 `ChromePlusUpdater.bat` 即可启动（首次启动时如果杀毒软件询问，请放行；脚本本身不联网之外的任何写入）。启动器通过 wscript 以隐藏方式启动 PowerShell，不会出现黑色终端框 / Windows Terminal 窗口。需要联网访问 Google 更新服务和 GitHub。

界面按钮：

| 按钮                | 功能                                                      |
| ------------------- | --------------------------------------------------------- |
| 检查更新            | 查询 Chrome 与 Chrome++ Next 的最新版本，并与本地版本对比 |
| 一键更新 / 一键构建 | 先检查，再按需构建 / 更新 Chrome 与 Chrome++ Next         |
| 更新 Chrome         | 强制重新下载构建 Chrome（已是最新时会先询问）             |
| 更新 Chrome++ Next  | 强制从 GitHub release 下载并更新 Chrome++ Next            |
| 启动浏览器          | 启动 `App\chrome.exe`                                     |
| 打开目录            | 在资源管理器中打开 `App` 目录                             |
| 编辑配置            | 用记事本打开 `App\chrome++.ini`                           |
| 取消                | 取消正在进行的操作                                        |

版本号来源：

- Chrome：`App\chrome.exe` 的 `ProductVersion`；最新版本通过 Google `update2` API 查询（`update_check.xml` 已硬编码进脚本）。
- Chrome++ Next：`Tool\chrome_plus\version-x64.dll` 的 `ProductVersion`（与 `FileVersion` 相同）；最新版本通过 GitHub Releases API 查询 `Bush2021/chrome_plus`，下载其 `setdll.7z`。

## 更新逻辑

### Chrome 更新

1. 备份 `App\chrome++.ini`（用户配置，更新后自动恢复）；
2. 下载 `ChromeStandaloneSetup64.exe`（约 160MB，优先使用 `Tool\Wget\wget.exe`，失败时回退内置下载器）；
3. 解压链路：安装包 → `updater.7z` → `chrome_installer.exe` → `chrome.7z` → `Chrome-bin`；
4. 在临时目录组装新的 `App`，用 `setdll-x64.exe` 注入 `version-x64.dll`，放入 `chrome++.ini` 与 `version-x64.dll`；
5. 成功后整体替换 `App`（先备份为 `App_old`，失败自动回滚）。

### Chrome++ Next 更新

1. 下载最新 release 的 `setdll.7z` 并解压；
2. 覆盖更新 `Tool\chrome_plus` 目录中的 x64 工具：`setdll-x64.exe`、`version-x64.dll`、`chrome++.ini`（默认配置，不保留 arm64/x86 版本）；
3. 同步 `App\version-x64.dll`（**不覆盖** `App\chrome++.ini` 中的用户配置）。

## 文件说明

```text
ChromePlusUpdater.ps1   主程序（GUI，兼容 Windows PowerShell 5.1 与 PowerShell 7，update_check.xml 已内置）
ChromePlusUpdater.bat   启动器（用隐藏窗口的方式启动，避免弹出终端）
ChromePlusUpdater.vbs   推荐启动器（wscript 无控制台，彻底避免终端窗口闪现）
Tool\7-Zip\             7-Zip 工具（7z.exe + 7z.dll 完整版，7za.exe 兜底；7zr.exe 仅作临时引导、用后即删）
Tool\chrome_plus\       Chrome++ Next x64 工具（setdll-x64.exe / version-x64.dll / chrome++.ini）
Tool\Wget\              wget.exe（缺失时自动从 eternallybored.org 下载）
App\                    构建出的便携版 Chrome（运行目录）
Temp\                   临时目录（所有下载与解压均在 Temp 中进行，任务完成后自动删除）
```

## 注意事项

- 更新 Chrome 前会自动关闭正在运行的便携版 Chrome；系统安装的 Chrome 不受影响。
- 每次运行都会检查 Tool 完整性，缺失时自动恢复（按 wget → 7-Zip → Chrome++ Next 的顺序）：
    - `wget.exe` —— 从 eternallybored.org 下载；
    - `7z.exe` + `7z.dll`（完整版，支持全部格式）—— 从 [ip7z/7zip release](https://github.com/ip7z/7zip/releases/latest) 动态获取最新版本：临时下载 `7zr.exe` 引导解压 `7z2602-extra.7z` 得到 `7za.exe`（7zr 用后即删），再用 `7za.exe` 解压最新 `7zNNNN-x64.exe` 得到 `7z.exe` + `7z.dll`；
    - `setdll-x64.exe` / `version-x64.dll` / `chrome++.ini` —— 从 [chrome_plus release](https://github.com/Bush2021/chrome_plus/releases/latest) 的 `setdll.7z` 恢复（仅 x64）。
- GitHub API 匿名请求有每小时 60 次的频率限制，短时间内反复“检查更新”可能失败，等待一小时或稍后再试即可。
