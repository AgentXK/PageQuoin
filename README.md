# PageQuoin

PageQuoin 是一个自用极简 LaTeX 编辑器，完全由 GPT 生成。

它采用英文界面，在 macOS 上本地运行。除了 LaTeX 和其他纯文本文件，也可以在标签页中查看常见格式的图片和 PDF。Tectonic 编译生成的 PDF 会显示在右侧预览区。

## 下载

从 GitHub Releases 下载 macOS ZIP，解压后将 `PageQuoin.app` 拖入「应用程序」目录。[下载 PageQuoin](https://github.com/AgentXK/PageQuoin/releases)

发行包使用 ad hoc 签名，尚未经过 Apple 公证。首次打开时如遇到 macOS 拦截，可查阅 Apple 的打开应用指南。[Apple 支持](https://support.apple.com/en-us/102445)

## 使用

需要 macOS 13 或更新版本。若还未安装编译引擎，可以通过 Homebrew 安装。 [Tectonic 安装文档](https://tectonic-typesetting.github.io/book/latest/installation/)

```sh
brew install tectonic
```

打开 `PageQuoin.app` 即可用内置模板开始编辑。按 `⌘O` 或双击文件树中的文件，可在编辑区打开 `.tex`、Markdown、JSON、CSV、代码等纯文本文件，以及 PNG、JPEG 等图片和 PDF。图片和 PDF 在标签页中以只读方式打开。应用会在 Homebrew 等常见路径寻找 Tectonic，也可以通过 **Build → Choose Tectonic…** 手动选择可执行文件。

紧凑顶栏中的项目名可以打开项目文件夹、查看最近项目或在 Finder 中定位当前项目。侧边栏的 **Files** 默认浏览当前文件所在的目录。点击标题右侧的图标可在选中文件夹或选中文件所在目录中创建文件、文件夹。没有选中项时使用项目根目录。新建文件省略扩展名时会补上 `.tex`。右键点击 **Files** 标题可刷新文件树或选择项目根目录。

侧边栏的 **Outline** 从主文档沿 `\input` 和 `\include` 展开项目的章节结构。点击标题可打开对应文件并跳到该章节。拖动侧边栏与编辑区之间的分隔线可调整侧栏宽度，拖动侧栏中间的分隔线可调整上下区域高度。

**File → Recent Projects** 记录打开过的目录。正常退出后，再次从应用图标启动时会恢复上次的项目、已保存标签、编辑光标和分栏。启动编译成功后，预览会恢复该项目的 PDF 页码、缩放和阅读位置。用 Finder 直接打开文件时，会优先打开所选文件。

编辑器高亮光标所在的屏幕行，长行换行后只高亮当前一段。**PageQuoin → Settings…** 可调整编辑字体、字号与行高，改动会即时应用到打开的编辑器，并保存在本机。行高使用百分比，默认是系统等宽字体、14 pt、120%。**View → Appearance** 可选择跟随系统、浅色或深色外观。

已命名的文件默认在停止输入 1000 毫秒后自动保存。可在同一设置窗口关闭自动保存或调长延时，最低为 1000 毫秒。用 `⌘N` 新建的未命名文档先用 `⌘S` 选择保存位置。

打开的文件在磁盘上发生变化时，干净的标签会自动刷新。有未保存的编辑时，应用会显示两份内容供比较，再由你选择继续编辑、从磁盘重载或保存自己的版本。

点击顶栏的项目名，在 **Main Document** 中选择项目的主文件。也可右键点击文件树中的 `.tex`，选择 **Set as Main Document**。**Automatic** 优先使用根目录的 `main.tex`，其次选择根目录中按文件名排列后第一个含 `\documentclass` 的 TeX 文件。项目的主文件和编译结果由各个标签页共享。

启动 PageQuoin 并恢复项目后，会自动用主文件编译一次。写作过程中仍可按 `⌘R` 手动编译。编译时点击 **Stop** 或按 `⌘.` 可结束当前编译，预览保留上一次成功生成的 PDF。另可开启 **Build → Auto Compile**，在停下输入约一秒后更新预览。

点击右上角的 **Search Project** 可搜索项目里的文本内容。用 **File → Quick Open…**（`⌘P`）按文件名或路径打开项目文件。右键文件树里的条目可复制项目内相对路径，或在 Finder 中定位。LaTeX 输入时自动提示命令、数学符号和环境名称。用方向键选择，按 Tab 或回车插入，按 Escape 关闭。

在 **Search Project** 中开启 **Replace** 可预览替换前后的内容，再按文件勾选并确认。打开的文件通过编辑器修改，可在各自的标签里撤销。其余文件写回磁盘。预览生成后发生改动的文件会被跳过。

输入 `\cite{` 可按引用键、作者、年份或标题筛选项目里的 `.bib` 条目。输入 `\ref{` 或 `\eqref{` 时可补全项目中的 `\label`。按住 Command 点击交叉引用键可跳到定义。

将 Finder 中的 PNG、JPEG 或 PDF 图稿拖到 LaTeX 编辑器，会插入使用相对路径的 `\includegraphics`。项目外的图片可确认复制到 `figures/`，同名文件会使用新文件名。编译图稿需要在导言区加载 `graphicx`。

**Search Project** 右侧的 **Layout** 菜单可切换 **Split View**、**Editor Only** 和 **PDF Only**。默认使用拆分视图，同一项目窗口内切换标签时会保留当前布局。

PDF 预览顶栏左侧可编译文档，中央可跳到首页、上一页、下一页或末页，右侧可缩放。也可以在 **Page** 后输入页码，按回车跳转。将指针放在 PDF 上方，按住 Control 并滚动鼠标滚轮即可缩放，普通滚轮用于翻阅。用 `⌘W` 或标签关闭按钮关闭最后一个文件后，项目窗口和文件树会保留。

在 PDF 预览获得焦点时按 `⌘F` 可查找正文，也可以用 **Edit → Find in PDF…**（`⌥⌘F`）直接打开 PDF 搜索栏。用回车和 `⇧` 加回车查找下一处或上一处。重新编译会保留预览缩放，并尽量回到原来的阅读位置。

编译后，把光标放在源码中，点击编辑区与预览区分隔线上的向右箭头，即可跳到 PDF。双击编译预览中的内容，可以跳回对应文件和行。**Build → Show Source in PDF** 和 `⇧⌘J` 也能从源码跳到 PDF。位置以最近一次成功编译为准。

编译产物集中放在项目根目录下的 `.pagequoin-build`。用 **Build → Show Build Files in Finder** 打开目录，用 **Build → Clean Build Files** 一键清理。项目源码和手动导出的 PDF 保留。

| 操作 | 快捷键 |
| --- | --- |
| 新建 | `⌘N` |
| 打开 | `⌘O` |
| 按文件名快速打开 | `⌘P` |
| 打开项目文件夹 | `⇧⌘O` |
| 下一个标签 | `Ctrl+Tab` |
| 关闭当前文件 | `⌘W` |
| 编辑器设置 | `⌘,` |
| 保存 | `⌘S` |
| 查找 | `⌘F` |
| 在项目中查找 | `⇧⌘F` |
| 跳到指定行 | `⇧⌘L` |
| 切换行注释 | `⌘/` |
| 补全 LaTeX 命令 | `⌥Esc` |
| 显示或隐藏侧边栏 | `⌥⌘S` |
| 编译和更新预览 | `⌘R` |
| 从源码跳到 PDF | `⇧⌘J` |
| 从 PDF 跳到源码 | 双击编译预览 |
| 显示或隐藏编译日志 | `⌘L` |
| 导出 PDF | `⇧⌘E` |

编译使用主文档及项目内已打开子文件的最新编辑内容，子文件需经项目内相对路径引用。混用未保存的子文件与项目外相对引用时，可以先保存子文件再编译。**Build Log** 的 **Problems** 标签列出编译错误和警告。点击带箭头的条目可跳到对应文件和行。**Raw Log** 显示原始日志。导出使用最近一次成功生成的 PDF。Tectonic 会在需要时下载缺失的宏包和字体，之后复用其本地缓存。 [Tectonic 文档](https://tectonic-typesetting.github.io/)

应用通过标准输入把编辑内容交给 Tectonic，因此编译日志和 LaTeX 的 `\jobname` 使用内部名称 `texput`。导出面板默认使用源文件的文件名。

## 从源码构建

使用配有 Swift 6 工具链的 Xcode 或 Command Line Tools，在项目目录运行以下命令。

```sh
./scripts/build-app.sh
open .build/PageQuoin.app
```

生成的 `PageQuoin.app` 可以拖进「应用程序」目录。运行 `./scripts/build-app.sh debug` 可生成调试版。打包时会把 `Assets/AppIcon.png` 生成 Finder 和 Dock 使用的应用图标。
