# PageQuoin

PageQuoin 是一个自用极简 LaTeX 编辑器，完全由 GPT 生成。

提供 macOS 桌面版，以及支持 Windows、Linux 和 macOS 的终端版。两版均使用 Tectonic 编译。 [下载安装包](https://github.com/AgentXK/PageQuoin/releases/latest) · [Tectonic 安装文档](https://tectonic-typesetting.github.io/book/latest/installation/)

## macOS 桌面版

需要 macOS 13 或更新版本。下载 macOS 通用 ZIP（支持 Apple Silicon 和 Intel），解压后将 `PageQuoin.app` 拖入「应用程序」。安装 Tectonic 可运行 `brew install tectonic`，也可在应用里通过 **Build → Choose Tectonic…** 选择已安装的编译器。

- 用 **File → Open Project Folder…** 打开项目。文件树随磁盘变化刷新，大纲可跳转到章节。
- 编辑区支持标签、自动保存和 LaTeX 补全。按 `⌘R` 编译，在右侧查看 PDF，双击预览可跳到源码。
- 用 **Build → Clean Build Files** 清理当前项目的编译缓存。

发行包使用 ad hoc 签名，尚未经过 Apple 公证。 [首次打开应用的说明](https://support.apple.com/en-us/102445)

## 终端版

安装 Node.js 22 或更新版本（含 npm）和 Tectonic。以下命令以 `pagequoin-terminal-1.2.0.tgz` 为例，其他版本请换成实际下载的文件名。 [Node.js 下载](https://nodejs.org/en/download/)

### Windows 安装

将终端版 `.tgz` 下载到「下载」文件夹。x64 Windows 可下载 Tectonic 的 `x86_64-pc-windows-msvc.zip`，把 `tectonic.exe` 解压到 `%LOCALAPPDATA%\Tectonic`，再在 PowerShell 中运行以下命令。 [Tectonic 下载](https://github.com/tectonic-typesetting/tectonic/releases/latest)

```powershell
$env:TECTONIC_PATH = "$env:LOCALAPPDATA\Tectonic\tectonic.exe"
& $env:TECTONIC_PATH --version
npm.cmd install -g "$env:USERPROFILE\Downloads\pagequoin-terminal-1.2.0.tgz"
Set-Location 'C:\Documents\paper'
pq.cmd
```

把示例项目路径换成实际目录。若 `tectonic.exe` 已在 `PATH` 上，可直接运行 `tectonic --version`。上面的 `TECTONIC_PATH` 仅在当前 PowerShell 窗口生效。

### macOS 和 Linux 安装

在下载目录安装终端版 `.tgz`，再切换到项目目录运行 `pq`。

```sh
npm install -g ./pagequoin-terminal-1.2.0.tgz
cd /path/to/project
pq
```

### 常用操作

- 用 `pq resume`（Windows 用 `pq.cmd resume`）打开最近项目。选中项目后按 `Delete` 可移除恢复记录，项目文件会保留。
- 工作区沿用终端背景，支持鼠标、自动保存、文件树、大纲及 LaTeX 补全。按 `Ctrl+U` 查看快捷键。
- 点击 **Build**（`Ctrl+R`）在主文件旁生成同名 PDF。**Open PDF**（`Ctrl+P`）在浏览器打开预览，**Clean** 清理编译中间文件。

在同一台 Mac 的同一账号下，两版共享主文档设置、最近项目、打开的源码标签和光标位置，以及最近成功的 PDF 预览。

## 从源码运行

macOS 桌面版需要 Swift 6 工具链。在仓库根目录运行以下命令。

```sh
./scripts/build-app.sh
open .build/PageQuoin.app
```

终端版可用以下命令从源码启动。

```sh
cd terminal
npm ci
npm start -- /path/to/project
```
