# Chrome 便携版更新器

检查并更新 **Google Chrome 便携版** 与 **Chrome++ Next 增强插件**，显示两者的版本号。首次运行时 Tool 中的工具会自动下载，仅需一个 exe 即可完成全部构建与更新。

## 项目结构

```text
项目根目录\
  ChromePlusUpdater.ps1     主程序（引擎本体，update_check.xml 已内置）
  Launch.vbs                启动器（wscript 无控制台，避免终端窗口；双击即可使用）
  README.md
  Build_exe\
    Launcher.cs             exe 的 C# 源码（重新生成 exe 时必需）
    build_exe.bat           重新生成 exe 的编译脚本（使用系统自带 csc.exe）
```

`ChromePlusUpdater.exe` 不随项目存放：运行 `Build_exe\build_exe.bat` 后会生成到项目根目录（与 `ChromePlusUpdater.ps1` 同级）。

运行后会在项目根目录自动生成：

```text
  Tool\7-Zip\       7-Zip 工具（7z.exe + 7z.dll 完整版，7za.exe 兜底；缺失自动下载）
  Tool\chrome_plus\ Chrome++ Next x64 工具（setdll-x64.exe / version-x64.dll / chrome++.ini）
  Tool\Wget\        wget.exe（缺失自动下载）
  App\              构建出的便携版 Chrome（运行目录）
  Temp\             临时目录（下载与解压均在此进行，任务完成后自动删除）
```

## 使用方式

双击项目根目录下的 `Launch.vbs` 即可启动（wscript 无控制台，不出现黑色终端框 / Windows Terminal 窗口）。也可以运行 `Build_exe\build_exe.bat` 生成单文件 exe 后双击，或直接运行：

```text
powershell -NoProfile -ExecutionPolicy Bypass -STA -File ChromePlusUpdater.ps1
```

需要联网访问 Google 更新服务和 GitHub。

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

下载与取消：

- 下载时界面会实时显示百分比、速度与剩余时间（状态栏 + 进度条）；
- 点击“取消”会立即停止当前下载/操作，不再继续后续步骤，日志输出“操作已取消”，临时目录也会被清理。

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

## 注意事项

- 更新 Chrome 前会自动关闭正在运行的便携版 Chrome；系统安装的 Chrome 不受影响。
- 每次运行都会检查 Tool 完整性，缺失时自动恢复（按 wget → 7-Zip → Chrome++ Next 的顺序）：
    - `wget.exe` —— 从 eternallybored.org 下载；
    - `7z.exe` + `7z.dll`（完整版，支持全部格式）—— 从 [ip7z/7zip release](https://github.com/ip7z/7zip/releases/latest) 动态获取最新版本：临时下载 `7zr.exe` 引导解压 `7z2602-extra.7z` 得到 `7za.exe`（7zr 用后即删），再用 `7za.exe` 解压最新 `7zNNNN-x64.exe` 得到 `7z.exe` + `7z.dll`；
    - `setdll-x64.exe` / `version-x64.dll` / `chrome++.ini` —— 从 [chrome_plus release](https://github.com/Bush2021/chrome_plus/releases/latest) 的 `setdll.7z` 恢复（仅 x64）。
- **重新生成 exe**：修改 `ChromePlusUpdater.ps1` 后，进入 `Build_exe` 目录运行 `build_exe.bat`，新的 `ChromePlusUpdater.exe` 会生成到**项目根目录**（与 `ChromePlusUpdater.ps1` 同级；脚本读取上级目录的 ps1，`Launcher.cs` 需与脚本同目录）。
- **exe 的基目录**：exe 与 ps1 同级（项目根）时以项目根为基目录（Tool/App/Temp 生成在项目根）；若把 exe 单独复制到其他位置，则以 exe 所在目录为基目录，保持“复制即用”的便携行为。
- GitHub API 匿名请求有每小时 60 次的频率限制，短时间内反复“检查更新”可能失败，等待一小时或稍后再试即可。
