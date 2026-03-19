# Google Chrome Portable for Windows(x64)

## 使用方法

### 构建 Chrome 便携版

- 新建一个`Chrome`文件夹。
- 将`ChromePortable.exe`放在`Chrome`文件夹中。
- 运行并选择`[1] 自动配置(构建或检查更新)`。
- 脚本将自动创建`Chrome/App`文件夹，其中`Chrome/App/chrome.exe`为Chrome主程序。

### 更新 Chrome 便携版

- 需要更新Chrome时启动`Chrome/ChromePortable.exe`。
- 运行并选择`[1] 自动配置(构建或检查更新)`。
- 程序将自动检查更新，如果有更新将自动更新。
- 更新会保留原来的`chrome++.ini`。

### 文件夹结构示意

```
Chrome/                    # 任意名称文件夹
├─App/
│  ├─ chrome.exe           # Chrome 主程序
│  ├─ chrome++.ini         # Chrome++ Next 配置文件
│  ├─ chrome_proxy.exe
│  ├─ version-x64.dll
│  ├─ xxx.x.xxxx.xxx/
│  └─ Dictionaries/
├─ Cache/                  # 缓存文件夹(Chrome启动后创建)
├─ Data/                   # 数据文件夹(Chrome启动后创建)
└─ ChromePortable.exe      # Google Chrome Portable for Windows(x64)
```

## 工具

- [Chrome++ Next](https://github.com/Bush2021/chrome_plus/releases)
- [GNU Wget for Windows](https://eternallybored.org/misc/wget/)
- [7-Zip Extra](https://www.7-zip.org/download.html)
- [Bat To Exe Converter 3.0.8 (非官方)](https://github.com/tokyoneon/B2E)

### 生成 ChromePortable.exe

- 从[GNU Wget for Windows](https://eternallybored.org/misc/wget/)下载 `wget.exe`。
- 从[7-Zip Extra](https://www.7-zip.org/download.html)下载`Windows x86/x64 | 7-Zip Extra`。
- 解压`7zxxxx-extra.7z`得到`7za.exe`。
- 从[Chrome++ Next](https://github.com/Bush2021/chrome_plus/releases)下载`setdll.7z`。
- 解压`setdll.7z`得到`chrome++.ini`, `version-x64.dll`, `setdll-x64.exe`。
- 从项目下载`main.bat`, `update_check.xml`(检查更新查询版本时POST请求提交的文件)。
- 运行`Bat To Exe Converter`。
- 点击工具栏`打开`选择`main.bat`。
- 在右侧`选项`配置`EXE格式:`<`64位 |控制台(可见)`，`在退出时删除:`<`是`。
- `选项`中的`图标`可以自己定制。
- 在右侧`嵌入`点击下方`添加`按钮，添加以下6个文件。
- `wget.exe`, `7za.exe`, `chrome++.ini`, `version-x64.dll`, `setdll-x64.exe`, `update_check.xml`。
- 点击工具栏`转换`导出为`ChromePortable.exe`。

## 致谢

- [Chrome++ Next](https://github.com/Bush2021/chrome_plus)
