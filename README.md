# CodeLook

在 Finder 里按空格就能高亮预览代码和配置文件。`rust-toolchain.toml`、`.envrc`、`Tiltfile`、没有扩展名的脚本这类文件，也不会再只显示一个通用图标。

- 高亮用的是 Lithe 编辑器自己的语法引擎：同一套 TextMate 语法和配色方案，Lithe 里怎么上色，这里就怎么上色。
- 只排版、只上色屏幕上能看到的那几行。400 万字节的 Rust 文件、40 万行的 JSON，在 Quick Look 里打开大约 10–15 ms。
- 所有设置都在一个 YAML 文件里，没有设置界面。字体、配色、文件名对应的语言、新语言的语法，都在这个文件里改。

## 安装

```sh
curl -fsSL https://github.com/xiaoyumuxi/CodeLook/releases/latest/download/install.sh | bash
```

脚本会下载最新的 `CodeLook.zip` 并校验 sha256，然后装到 `~/Applications/CodeLook.app`。接着它按这台 Mac 的文件类型和你的 config.yaml 认领文件，注册扩展，重置 Quick Look。

需要 macOS 13 或更高版本。发布包是通用二进制，在 Apple 芯片和 Intel 上都原生运行，不经过 Rosetta。

| 用法 | 作用 |
| --- | --- |
| `curl -fsSL …/install.sh \| bash -s -- --version v0.1.0` | 安装指定版本 |
| `bash install.sh --zip ~/Downloads/CodeLook.zip` | 用从 Releases 页面下载的包安装 |
| `… --dir /Applications` | 换一个安装目录（默认是已安装的位置，否则 `~/Applications`） |
| `install.sh --refresh` | 在 config.yaml 里新加了扩展名之后，重新认领 |
| `install.sh --uninstall` | 卸载，`~/.config/codelook` 会保留 |

装好以后，脚本也在 App 里：`~/Applications/CodeLook.app/Contents/Resources/install.sh`。

- **签名**：App 只有 ad-hoc 签名，没有经过 Apple 公证。用 curl 下载的文件不带隔离属性。从浏览器下载的 zip 带隔离属性，Gatekeeper 会拦下它，所以请用 `install.sh --zip` 安装，脚本会去掉隔离属性。
- **安装时为什么要改 App**：发布包只认领通用的类型。这台 Mac 上其他 App 声明的类型（例如编辑器给 `.ltx` 声明的 `org.tug.ltx`），以及 config.yaml 里新加的扩展名，要在安装时写进 Info.plist（`CodeLook --update-claims`），写完再重新做一次 ad-hoc 签名。
- **旧副本**：如果别处还注册着一份 CodeLook（旧的下载、源码构建的产物），它会和新装的抢着处理预览。脚本会取消它的注册，但不删除文件。

## 从源码构建

需要的工具：Xcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、Go（版本见 `Bridge/go.mod`）。语法引擎的代码就在本仓库的 `Bridge/internal/` 里，不依赖其他仓库。

```sh
GOPROXY=off make install   # 构建并安装到 ~/Applications/CodeLook.app，同时注册扩展、重置 Quick Look
make uninstall
```

| 命令 | 作用 |
| --- | --- |
| `make` | 构建 Lithe 语法库，生成 plist 和 Xcode 工程，编译 Release |
| `make config` | 从示例创建 `~/.config/codelook/config.yaml`（已存在就不动） |
| `make check` | 列出这台 Mac 把各类文件识别成什么类型，以及 CodeLook 怎么覆盖它们 |
| `make render F=文件` | 不安装就能预览：打印耗时，并输出 `/tmp/codelook-preview.png`（`ARGS=--dark` 生成深色版） |
| `make test` | 引擎的 Go 测试，再对 `Samples/` 里的样例做一遍冒烟测试 |
| `make dist` | 发布包：通用二进制的 `build/dist/CodeLook.zip`，加上 `.sha256` 和 `install.sh`（用 `VERSION=1.2.3` 指定版本号） |

- **体积**：`make` 只为本机架构编译，App 大约 13 MB。`make dist` 同时包含 arm64 和 x86_64，App 大约 23 MB，zip 约 7 MB。体积主要是 Go 引擎（`Contents/Frameworks/libLitheSyntax.dylib`，每种架构约 7.5 MB），App 和两个扩展共用这一份。只要 Apple 芯片的包：`make dist DIST_ARCHS=arm64`。
- **认领的类型**：源码构建会直接认领本机的类型和 config.yaml 里的扩展名。发布包不带构建机上的这些类型，留到用户安装时再认领。

### 发布

推送 `v*` 标签后，GitHub Actions（`.github/workflows/release.yml`）会依次：

1. 跑测试；
2. 编出通用包，并试装一遍；
3. 创建 Release，附上 `CodeLook.zip`、`CodeLook.zip.sha256` 和 `install.sh`。

```sh
git tag v0.1.0 && git push origin v0.1.0
```

在 Actions 页面手动运行这个 workflow，只构建，不发布，包会保存在这次运行的 artifact 里。

### 为什么是一个 App

macOS 15 起，系统不再加载旧式的 Quick Look 插件（`.qlgenerator`）。预览只能由 App Extension（`.appex`）提供，而扩展必须放在某个 App 的 `Contents/PlugIns/` 里，随 App 一起被系统登记。

所以 CodeLook.app 只是装扩展的容器。平时不用打开它，只要它放在 `~/Applications` 或 `/Applications` 里并登记过，按空格就由扩展处理。安装脚本和 `make install` 都会完成登记。扩展可以在“系统设置 → 通用 → 登录项与扩展 → 快速查看”里开关。

打开 App 能看到扩展是否启用、配置文件有没有问题，也能在里面一键修复注册。

## 配置

配置文件是 `~/.config/codelook/config.yaml`，可以用环境变量 `CODELOOK_CONFIG` 换成别的路径。没有这个文件时全部用默认值。

创建方式有两种：运行 `make config`，或者在 CodeLook App 的“状态”页点“从示例创建并打开”。示例文件是 [`Examples/config.example.yaml`](Examples/config.example.yaml)，里面每一项都有说明，写的值就是默认值。

- **什么时候生效**：保存后的下一次预览，不用重启，也不用重装。引用的语法文件改了也一样，会自动重新读取。
- **什么时候要重新认领**：在 `files` 或 `grammars` 里新加了扩展名。这些扩展名要写进扩展的 Info.plist，Quick Look 才会把这类文件交给 CodeLook。
  - 运行 `~/Applications/CodeLook.app/Contents/Resources/install.sh --refresh`；从源码安装的，重新 `make install`。
  - 也可以在 App 的“状态”页点“重新认领并注册”：App 会退出，运行 App 里的这个脚本，再带着输出重新打开。还没认领的扩展名会列在“配置文件”一栏里。
  - 原本系统不认识的扩展名，会被登记为 `dev.openres.codelook.user` 类型。
  - 新加的文件名不用重新认领：没有类型的文件本来就交给 CodeLook 的兜底扩展处理。
- **写错了怎么办**：写错的那一项会被跳过，其余设置照常生效。问题会显示在预览顶栏（`⚠︎ config.yaml: …`，鼠标悬停可以看全部），App 的“状态”页也会列出来。

```yaml
font:
  family: JetBrains Mono      # 可以用逗号写多个，第一个可用的生效
  size: 12
  lineHeight: 1.5             # ≤ 4 表示字号的倍数，> 4 表示 pt
  ligatures: false

view:
  tabWidth: 4
  lineNumbers: true

theme:
  scheme: lithe               # lithe、idea、vscode、github、one，和 Lithe 编辑器一致
  italicComments: false
  tokens:                     # 浅色和深色都生效
    comment: "#8C8C8C italic"
  light:
    background: "#FFFFFF"
    tokens: { keyword: "#0033B3 bold" }
  dark:
    background: "#191A1C"

files:                        # 指定文件名用哪种语言，优先级最高
  "*.tpl": html
  ".envrc": shellscript
  Tiltfile: python

grammars:                     # 给 Lithe 没有的语言加语法
  - language: diff
    name: Diff
    grammar: grammars/diff.tmLanguage.json
    extensions: [diff, patch, rej]
    scopes:
      markup.inserted: markup.inserted
      meta.diff.range: markup.heading

limits:
  maxFileSize: 8MB
  maxLines: 1000000
```

### 字体

默认字体是 JetBrains Mono。它已经打包在 App 里，不需要安装，也不会被注册到系统里。其它字体要先装在本机，填字体族名（例如 `Menlo`、`SF Mono`）或 PostScript 名都可以。

找不到字体时，依次退回到打包的 JetBrains Mono 和系统等宽字体，并提示一条问题。连字默认关闭，所以 `->`、`!=` 会按原样显示成两个字符。

### 修改高亮

`theme.tokens` 的键有两种写法：

- 角色：`comment keyword string number type function variable property constant boolean null tag attribute punctuation operator regex`。
- Lithe 的 token 名，按最长的点分前缀匹配，例如写 `comment.documentation`，只改 `/** … */` 这类文档注释。不同语言的 token 名不一样，可以到 `Bridge/internal/syntax/languages.go` 里查。

值的写法是 `"#RRGGBB"`，后面可以跟 `bold`、`italic`、`underline`、`strikethrough`。写 `regular` 会去掉粗体和斜体。只写样式、不写颜色也可以，例如 `keyword: bold`。

写在 `theme.light.tokens` 或 `theme.dark.tokens` 下的规则，只对对应的外观生效。

`light` / `dark` 下还可以设置 `background`、`text`、`lineNumber`、`selection`。

### 扩展格式

- **已有的语言，换一种文件名**：写在 `files` 里。语言可以是 Lithe 的 id（`rust`、`python`、`yaml`、`jsonc`、`shellscript` …），也可以是 CodeLook 自带的 id（见 `Shared/LanguageTable.swift`）。写 `plaintext` 表示不高亮。
- **新的语言**：写在 `grammars` 里，指向一个 TextMate 语法文件（`.tmLanguage.json`，或者用 YAML 写的语法）。`scopes` 把语法里的 scope 映射成 token 名：冒号左边的 scope 会匹配它自己和它的子 scope，没写到的按 Lithe 的默认规则映射（comment、string、keyword …）。映射出来的 token 名可以直接在 `theme.tokens` 里设置颜色。示例 `Examples/grammars/diff.tmLanguage.json` 就是这么给 diff/patch 上色的。

### 沙盒限制

Quick Look 扩展运行在沙盒里，只能读取 `~/.config/codelook/` 下面的文件。所以：

- 语法文件要放在这个目录里，比如 `~/.config/codelook/grammars/`。
- 如果 `~/.config/codelook` 是指向别处的符号链接，扩展读不到里面的文件。

## 架构

```
Bridge/      Go：把 Lithe 的语法引擎编译成 C 动态库（libLitheSyntax.dylib + .h）
             App 和两个扩展共用 Contents/Frameworks 里的这一份
             bridge.go 负责分词和配色，config.go 负责读取 config.yaml、应用主题、加载语法
             internal/ 是从 Lithe 复制过来的引擎（来源见 Bridge/internal/README.md）
Shared/      Swift：读取文本（编码、二进制检测）、判断语言、按配置生成样式、CodeTextView 视图
Extension/   两个 Quick Look 扩展：
             CodeLookPreview 认领具体的文件类型；
             CodeLookFallback 认领 public.data，接住系统叫不出类型的文本文件，二进制文件交还给系统
App/         宿主 App：查看安装和配置状态，列出还没认领的扩展名，重新认领并注册（不提供设置）
             CodeLook --update-claims：给安装脚本用，把本机的类型和 config.yaml 的扩展名写进自己的 Info.plist
Tools/gen    生成三个 Info.plist 里认领的类型（会读取 config.yaml 里的扩展名；--release 两者都不读）
             这些 plist 每次 make 都会重新生成，内容因机器而异，所以不入库
scripts/     install.sh：下载、校验、认领、重新签名、注册；也打包在 App 的 Resources 里
.github/     release.yml：推送 v* 标签时构建通用包并发布 Release
Tools/render 命令行渲染，用来测耗时和截图
```

文件交给哪种语言，按下面的顺序判断：

1. config.yaml 的 `files`
2. config.yaml 的 `grammars`
3. Lithe 的文件类型
4. CodeLook 自己的语言表（文件名、扩展名、前缀）
5. 文件内容（shebang、modeline 等）

### 性能

- 打开文件时，只做一遍 UTF-8 → UTF-16 的转换，同时算出行首位置和每行宽度。
- 视图的行高固定，滚动条长度直接按行数算出来。只有比视图宽的行才去找换行位置。
- 一行第一次出现在屏幕上时才排版（CTLine）。
- Lithe 的分词器从最近的检查点开始，只分要画的那几行。剩下的检查点由后台 goroutine 慢慢补齐，补完后如果某些行的颜色变了，只重画这些行。
- 配置每个进程只解析一次，大约 5–8 ms。之后每次预览只检查一下配置文件和语法文件有没有变化。

实测耗时（Quick Look 中，从读取文件到画出第一屏）：

| 文件 | 行数 | 耗时 |
| --- | --- | --- |
| big4m.rs（4 MB） | 117,480 | 10.6 ms |
| big.json | 400,002 | 14.6 ms |
| 小文件 | — | 0.5–2 ms |

## 排查

```sh
make check                                                     # 某类文件有没有被认领
make render F=path/to/file                                     # 引擎和配置在命令行下的表现
log stream --predicate 'subsystem == "dev.openres.CodeLook"'   # 扩展每次预览的语言、字体、耗时，以及配置里的问题
```

## 许可

JetBrains Mono 字体使用 SIL Open Font License 1.1，见 `Resources/Fonts/JetBrainsMono-OFL.txt`。语法引擎、语法文件和配色方案来自 Lithe。
