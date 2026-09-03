# HANDOFF — AgentBookReader 交接文档

> 接手前必读。代码可运行、测试全绿（42 个）。已提交并推送到 GitHub：https://github.com/Dashi929/AgentBookReader（main 分支）。

## 一、项目概况

- **是什么**：跨平台电子书阅读器（Android/iOS/Windows/Linux），内置 AI Agent（对话问答、批注、改写提案）与翻译（整页/选块，多提供方）
- **路径**：`D:\Projects\AgentBookReader`（包名 `agent_book_reader`，org `com.openleaf`）
- **技术栈**：Flutter 3.47.2 / Dart 3.13.2 · Riverpod · drift(SQLite) · http · file_selector · enough_convert · flutter_secure_storage · pdfrx 2.5.0(PDF)
- **规模**：40 个 dart 文件 / ~7000 行 / 34 个自动化测试
- **Git**：已提交并推送到 GitHub `Dashi929/AgentBookReader`（main；用户规矩：他说"提交/推送"才能动）
- **运行产物**：Windows `build\windows\x64\runner\Release\agent_book_reader.exe`；Android `build\app\outputs\flutter-apk\app-release.apk`

## 二、环境（每次会话第一步）

```powershell
$env:Path += ';D:\dev\flutter\bin'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
```
- Flutter 装在 `D:\dev\flutter`（用户级 PATH 已配）
- Windows 桌面构建需 VS 2026 C++ 工作负载（已装）+ **系统开发者模式**（已开，注册表 AppModelUnlock\AllowDevelopmentWithoutDevLicense=1）
- iOS 不能在 Windows 构建
- Android 构建可用：SDK 在 `C:\Users\11020\AppData\Local\Android\sdk`；**JDK 17 在 `D:\dev\jdk-17\jdk-17.0.2`**（系统 PATH 只有 JDK 11，Gradle 9.6 要求 17+，已在 `android/gradle.properties` 用 `org.gradle.java.home` 指定）；cmdline-tools 已补装（`cmdline-tools\latest`，sdkmanager/avdmanager 可用）
- **Android 模拟器可用**：BIOS SVM 已开启（2026-09-02），WHPX 加速正常；AVD `AgentReader`（Pixel 5 外形，system-images;android-35;google_apis;x86_64 已装）

## 三、固定开发循环（用户明令要求）

1. `flutter analyze` → **0 问题**才算完
2. `flutter test` → **全绿**才算完
3. `flutter build windows --release`（**先杀运行中的 exe**，否则 LNK1104 文件锁）
4. 启动 exe 自测当次功能，向用户报告；**绝不主动 git 提交**
5. 用户反馈 bug → 定位（写诊断测试 print 中间态）→ 修 → 重跑全流程

## 四、架构速查

```
lib/
├── core/                  # 纯 Dart（pagination 除外用 painting），可单测
│   ├── model/             # Document/Section/Paragraph、Annotation/DocTextEdit、
│   │                      # CharRange（全文偏移坐标系——进度/Agent/批注统一基准）、
│   │                      # RichSegment(文本+样式)、DocFormat(txt/md/json/docx/epub)
│   ├── parser/            # DocumentParser 基类 + Txt/Md/Json/Docx/Epub 五个提取器
│   ├── pagination/        # Paginator：TextPainter 行级度量、段落跨页、样式随行切片
│   ├── controller/        # DocumentController 接口（M1 冻结）+ PlainTextDocument
│   └── io/text_decoder.dart  # 编码探测：BOM→UTF-8→GBK→UTF-16(手写)启发式
├── agent/
│   ├── llm_client.dart    # OpenAI 兼容非流式 chat；baseURL 防呆归一化(自动补/v1)；
│   │                      # tool_calls 解析；默认超时 300s
│   ├── tools.dart         # AgentToolHandler 公共接口 + AgentToolRegistry（阅读器，
│   │                      # 仅当前文档）：get_outline/read_section/search_text/
│   │                      # add_annotation/propose_rewrite（写→提案确认，不直接改）
│   ├── workspace_tools.dart # WorkspaceToolRegistry（工作台，多文档）：所有工具带
│   │                      # doc_id + list_documents；propose_rewrite 确认后写回
│   │                      # 原文件（txt/md/json 备份 .bak；docx/epub 仅内存）
│   ├── translation_task.dart # 整篇翻译一键任务：逐节调 provider（md 剥标题行）、
│   │                      # 结果按 (docId,sectionIndex,lang) 缓存进 Translations 表、
│   │                      # assembleTranslationMarkdown 纯函数拼装 → 导出 <原名>.<lang>.md
│   ├── agent_loop.dart    # 工具循环 maxTurns=8，onEvent 事件回调，接受任意 AgentToolHandler
│   ├── translation_providers.dart  # 抽象 + LLM/MyMemory(免费无key,450字分块)/Google gtx
│   └── agent_settings.dart # baseURL/apiKey/model 存 flutter_secure_storage（无预设，全手填）
├── infra/
│   ├── database.dart      # drift 5 表：Documents/Annotations/AgentSessions/
│   │                      # AgentMessages/Translations（schemaVersion 1）
│   └── agent_repository.dart # 会话/消息/批注 DB 访问（loadLlmHistory 只回放 user/assistant）
├── state/app_state.dart   # PrefsService(主题/字号/翻译服务/目标语言) + LibraryNotifier(drift)
└── ui/                    # library_page(书架+批量导入+工作台入口) reader_screen(阅读器)
                           # agent_panel(阅读器悬浮助手，只能处理当前文档)
                           # agent_workspace_page(Agent 工作台，可勾选多文档，免预选直接聊)
                           # edit_section_screen 已删除（编辑就地化）agent_settings_screen(LLM 配置)
```

**关键设计决策（不可轻易破坏）**
1. **CharRange 全文偏移坐标系**：进度/Agent 读写/批注统一基准；txt/json 段落切片==原文 substring（严格不变式），md 为渲染后文本（标记剥离）但偏移仍映射原文
2. **DocumentController 接口 M1 冻结**：EPUB/DOCX 都是"提取→Markdown/纯文本→复用解析管道"，新格式只加实现
3. **Agent 写操作一律"提案-确认"**：propose_rewrite 产生 RewriteProposal → UI 弹窗 → 用户确认才 applyEdit；原文件永不自动覆盖（手动编辑写回原文件时备份 .bak）
4. **翻译无预设**：baseURL/Key/模型全手填 + 测试连接按钮；免费提供方 MyMemory 无需注册
5. **范围永久排除**（用户明令）：云端账号、书城/在线书源、本地大模型推理、向量库/RAG

## 五、踩坑清单（血泪，勿重蹈）

### Flutter/Dart
- **Release 构建必须加 `--no-tree-shake-icons`**：图标字体 tree-shaking 会把部分非 const 引用的 glyph（如 Icons.notes / speaker_notes_outlined）裁成空白按钮——按钮存在、a11y 可见但渲染为空。出现"图标丢失"先查这个
- **LLM 默认超时 300s**：整节/整篇翻译等长生成任务单次输出数千字，120s 必超时（报 TimeoutException after 0:02:00）。长任务要引导 Agent 按节分批（read_section 一节一轮），工作台 maxTurns=16
- `TextField maxLines>1` 时 **onSubmitted 永不触发**（Enter=换行）→ 单行 + `textInputAction.send`
- jsonEncode 不能编码懒 Iterable（`.map()` 结果必须 `.toList()`）
- 级联 `..x++` 不是合法语法（`..x = v` 才是）
- drift 生成行类与核心模型撞名（Documents→Document、Annotations→Annotation）→ `import database.dart hide Document, Annotation;`
- xml 包：XmlElement 是 `children` 不是 `childNodes`；`firstOrNull` 需 Dart 3（core 内置 ✓）
- enough_convert：GbkCodec 参数是 `allowInvalid`；**没有 UTF-16 codec**（手写解码，含代理对）
- flutter_test 字体是 Ahem：每字形宽=fontSize，度量确定性 → 分页测试可精确断言
- drift 测试用 `NativeDatabase.memory()`，宿主机缺 sqlite3.dll 时会抛 → 测试里 try/catch 跳过
- PageController.initialPage 无 setter：attach 前用构造参数，attach 后只能 jumpToPage（postFrameCallback + hasClients 双保险）

### PowerShell / 工具链（Windows Agent 专属）
- **PS 5.1 `Get-Content` 默认 ANSI（GBK）读 UTF-8 文件会损坏中文并吞换行** → 读写一律 `[System.IO.File]::ReadAllText/WriteAllText(path, Encoding.UTF8)`
- PS 5.1 `Set-Content` 遇路径含 `[ ]`（如 [Content_Types].xml）会被通配符展开 → 用 LiteralPath 或 .NET API
- `Compress-Archive` 不认 .docx/.epb 扩展名 → 先压 .zip 再改名；且可能产生**反斜杠 ZIP 条目** → 解包器必须归一化路径
- 工具壳里 `Thread.Sleep` 阻塞 Unity/Flutter 调试主线程 → 测帧用"分次调用采样"
- 输出过长会 ChildProcess.kill 外层 shell，但 **Start-Process -Verb RunAs 的提权子进程会继续跑完**；等待用日志文件轮询
- 搜索进程时 `Where CommandLine -like '*script*'` 会**自匹配**当前 shell → 用 PID 排除或精确匹配 .ps1 文件名

### Android 构建（2026-09 踩坑实录）
- **AGP 必须用 9.4.0+**：flutter_secure_storage v11 要求 compileSdk 37，而 Google 已把平台改名为 "Android SDK Platform 37.0"（目录 `android-37.0`）；AGP 9.1 找整数哈希 `android-37` 会报 "Failed to find target with hash string"。AGP 9.4 能正确映射（见 `android/settings.gradle.kts`）
- **AGP 9.4 要求 Gradle ≥ 9.6**：wrapper 已从 9.3.1 升到 9.6.0（`android/gradle/wrapper/gradle-wrapper.properties`）
- **app compileSdk 显式写 37**：`android/app/build.gradle.kts` 里 `compileSdk = 37`（不再用 flutter.compileSdkVersion）
- **必须 `kotlin.incremental=false`**：插件源码在 C 盘 pub 缓存、构建目录在 D 盘，Kotlin 增量缓存算相对路径跨盘符根直接炸（"Could not close incremental caches ... different roots"），已写进 gradle.properties
- NDK 28.2 / Build-Tools 36 / Platform 37.0 / CMake 3.22.1 会在首次构建时被 AGP 自动下载安装
- **模拟器跑不起来的根因排查顺序**：`emulator -accel-check` → 报 "hypervisor driver is not installed" 且 AEHD `StartService 失败 (错误 95)` + 事件日志 7026 "aehd 未加载" → `systeminfo` 看 "Virtualization Enabled In Firmware" → No 则必须进 BIOS 开 AMD **SVM Mode**（本机 5950X，台式机 Del 键进 BIOS）；开启后 WHPX 直接可用，无需重启装驱动
- **Release 包联网失败（Failed host lookup, errno=7）**：Flutter 模板只给 debug/profile 清单 INTERNET 权限，`src/main/AndroidManifest.xml` 没有 → release APK 里所有 HTTP 请求 DNS 直接被拒（18ms 内失败，不是超时）。已加 `<uses-permission android:name="android.permission.INTERNET"/>`，勿删

### 领域
- TextPainter 视觉行切分：行尾必须取"下一行起点(x=0)"，取"下一行几何+右边缘"会跨两行（渲染 maxLines:1 裁掉=丢内容）
- Windows 系统小 txt（如 PcaAppLaunchDic.txt）多为 UTF-16/ASCII 且行数极少——不是 bug
- 中文 txt 电子书常为 **GBK** 编码，必须走编码探测

## 六、当前状态与待办

### 已验证 ✅
- 导入 txt(UTF-8/GBK/UTF-16)/md/json/docx/epub → 分页阅读
- 翻页/主题(白护眼夜)/字号(段落锚定重排不丢位置)/进度记忆(drift)
- Agent 对话+工具调用（LLM 已配置可用）；批注入库+批注列表；改写提案确认
- 编辑模式（自动 .bak 写回）；整页/选块翻译（8 种目标语言可选并记忆，LLM/MyMemory/Google）
- **Agent 工作台**（书架右上角机器人入口）：多文档勾选（对话框按需弹出）、跨文档工具
  （list_documents/带 doc_id 的读写工具）、免预选直接聊（Agent 会引导勾选）、对话历史持久化
- **整篇翻译一键任务**：工作台"整篇翻译并导出"按钮 → 选语言 → 逐节翻译（进度/取消，
  结果缓存进 Translations 表，重跑续翻）→ 导出 `<原名>.<语言>.md`（已用真实 LLM 端到端验证）

### 用户尚未验收 / 已知待办
1. 待用户验收：选块翻译、批注列表、编辑写回、整篇翻译对 docx/epub 的效果
2. **已知 UX 缺陷（2026-09-02 模拟器实测发现）**：阅读器字号滑杆连续变更时段落锚定漂移——Slider 拖动/点击动画会连续触发 setFontSize，每次中间重排都以"当前页首段"为锚点，跨页段落场景下锚点逐级回退（实测从第 9 段漂到第 1 段）；初始定位/单次变更正常，数据无损。修法建议：onChanged 只预览、onEnd 才提交，或锚点取当前页中心线段落 + 防抖
   → **已修复（同日）**：滑杆 onChanged 只更新预览、onChangeEnd 一次性提交；锚点升级为字符级（`lib/core/pagination/page_anchor.dart`，4 个单元测试覆盖）；跨页段落中间行不再回退段首
3. **已修复存量 bug**：reader `_saveProgress` 在 dispose 里用 ref（riverpod 抛 "ref after disposed"，破坏帧收尾曾致语义树/渲染异常）→ initState 先捕获 LibraryNotifier
4. **就地编辑**：编辑按钮不再 push 新窗口，原界面覆盖编辑层（EditText + Confirm/导出/写回(.bak) 顶栏，标题"编辑 · 第N节"）；保存后 `_paginationKey = null` 强制重排
5. **PDF 支持（v2，文本管道统一）**：导入 .pdf → 打开时 `_extractPdf()` 异步提取——逐页 `loadText()` 文字、`loadOutline()` 书签扁平化为章节标题（`#`×(depth+1)，无书签则每页 `# 第 N 页`）、**无文字页（扫描页）用 `PdfPage.render` 整页渲染为图片占位段**；提取后走普通 md 文本管线（分页/进度/锚定/编辑/翻译/Agent 全部可用）；写回仅限 txt/md/json（PDF 编辑仅应用内+可导出 txt）；大 PDF 提取需数秒（加载态提示）
6. **内嵌图片（docx/epub）**：提取器输出整行占位段 `[[IMG:imgN]]` + ExtractedImage 列表（`extractAsMarkdownWithImages`；旧 `extractAsMarkdown` 委托兼容）；导入时图片落盘 `images/<entryId>/imgN.ext` + manifest.json（PNG/JPEG/GIF/BMP 文件头解析宽高）；分页 `ReaderPageConfig.imageLineHeight` 给图片段整行高度；阅读器 `Image.file` 渲染（错误回退占位文本）。**PDF 文本页内嵌图片暂不单独提取**（pdfrx 未暴露对象级 API），仅整页渲染兜底
6. ⚠️ pdfrx **1.3.5 有 release AOT 空安全编译 bug**（pdf_file_cache.dart 可空访问），必须用 2.x；pub get 曾重解析依赖（drift 2.31 等），改表后仍需 build_runner

### 下一步候选（M8+，按用户优先级）
- PDF 阅读（pdfium，`pdfrx` 包；渲染层独立但共享进度/批注体系）
- 批注在页面上**高亮渲染**（当前仅列表；需把 CharRange 映射到行切片）
- 翻译术语表（第一遍抽专名统一译名）；翻译任务 UI（进度条/暂停/并发）
- Agent 流式输出（SSE）；OPDS/书源已被用户永久排除
- 多语言补全（ARB 机制已就绪，新增界面必须同步 zh/en）

## 七、常用命令

```powershell
flutter analyze
flutter test
flutter build windows --release --no-tree-shake-icons   # 产物 Release\agent_book_reader.exe
flutter build apk --release --no-tree-shake-icons      # 产物 flutter-apk\app-release.apk（debug 签名，测试用）
# 安卓模拟器（AVD: AgentReader）
C:\Users\11020\AppData\Local\Android\Sdk\emulator\emulator.exe -avd AgentReader
adb install -r build\app\outputs\flutter-apk\app-release.apk
adb shell am start -n com.openleaf.agent_book_reader/.MainActivity
adb shell dumpsys package com.openleaf.agent_book_reader | findstr INTERNET   # 验证联网权限
flutter run -d windows            # 调试
flutter run -d chrome             # Web 调试（需 flutter create . --platforms web，已配）
dart run build_runner build --delete-conflicting-outputs   # drift 改表后必须跑
flutter gen-l10n                  # ARB 改后必须跑（或 flutter run 自动）
```

## 八、Android 模拟器功能实测（2026-09-02，AVD AgentReader / API 35）

- 通过：导入 txt（FAB→SAF→Downloads）、分页渲染、右侧点击翻页、进度记忆（强杀重启回第 2 页）、主题三档循环、字号调整与重排、Agent 对话（真实 LLM）、add_annotation 工具+批注列表、整页翻译（MyMemory→英文结果面板）、编辑本节保存、工作台（免预选引导→list_documents→勾选后 get_outline）、改写提案弹窗+Reject 原文不变
- 测试驱动：`uiautomator dump` 可读 Flutter 语义树（tooltip→content-desc、文本→text）；adb input 不支持中文，Agent 测试用英文提问（回复跟随提问语言，符合设计）；截图证据在 `build\test-android\`（01~10）

## 九、第二轮变更实测（2026-09-02 晚）
- 修复后回归：字号滑杆单次提交 + 字符级锚定（第2页跨页段落拖动不再回跳）；就地编辑（编辑层原界面出现→改文→Confirm→内容同步+原文件.bak 写回）
- 导入实测：docx（Heading1→# 分节正确）、epub（spine 双章+h1→# 正确）、pdf（pdfium 渲染、P1/P2 文本可见、滚动翻页、页码 "2 / 3"、强杀重启回到第 2 页）
- PDF 生成法：Chrome 无头 `--headless --no-pdf-header-footer --print-to-pdf` 从 HTML 打印（测试文件在 build/test-android/make/）
- uiautomator 语义树偶发抖动（重试可恢复；"null root node" 时等 2s 重试）；验证内容渲染可用截图像素统计（暗像素占比）

## 十、第三轮实测（2026-09-02 深夜）：PDF 文字化 + 内嵌图片
- PDF 文字化验证：pdf_test.pdf 打开后显示提取文本（PDF_P1_MARKER 等），章节按钮（menu_book，s.chapters）→ 目录列出 3 节（含起始页）→ 点"第 3 页"跳转到 P3 ✓；进度记忆照常
- 内嵌图片验证：docx/epub 各含 400x150 蓝色 PNG → 导入后截图像素统计蓝色块 23064 px（y 800-1168）✓；提取→落盘→manifest→分页→渲染全链路通
- 新增测试：page_anchor_test 4 个（字符级锚定回归）；46 个测试全绿
- 调试教训：PowerShell here-string 拼 patch 时行首 `+` 会被写进文件（两次事故）；PS 双引号会插值 `${var}`/`$p`——拼 Dart 代码一律用单引号 here-string；ReadAllText 后统一换行符再 Replace（混用 CRLF/LF 导致 Contains 失败）

## 十一、第四轮变更（2026-09-03）：真机导入修复 + PDF 原版渲染模式

### 导入修复（真机"没有权限"）
- **选择器不再按扩展名过滤**：XTypeGroup 传扩展名会被 file_selector_android 映射成 MIME 塞进 SAF EXTRA_MIME_TYPES，真机 ROM 实现不一致会导致文件全部置灰/报权限错；改为选择器全放行、应用内按扩展名校验并提示
- **导入即复制进应用私有目录**：`imported/<entryId>.<ext>`，DB 存该永久路径（file_selector 在 Android 返回 SAF 临时缓存路径，系统清缓存后重开/写回/PDF 渲染都会失败）
- **错误全部可见**：openFiles 异常捕获 + 单文件失败收集后 SnackBar 显示具体原因（原先 catch (_) 静默吞，表现为"没反应"）
- 旧书籍记录存的还是缓存路径，打不开需删掉重导

### PDF 原版渲染模式（用户反馈"图示全变文字"后重做）
- **阅读视图逐页 pdfium 渲染成图片**（InteractiveViewer 支持缩放），图示/版式 100% 保真；按需渲染+落盘缓存 `images/<entryId>/pdfpN.png`（manifest.json 复用），二次打开免渲染
- **文字提取仍保留**：全文构建 _doc 供 Agent 工具/批注/**整页翻译**用；显示与文字分离
- PDF 模式隐藏编辑/字号按钮；目录=书签跳页（无书签逐页列表）；翻译菜单只保留整页（选块需文本段落）；进度按 PDF 页码
- **旧 PDF 记录是文字模式入库，需删掉重新导入**才走渲染模式
- 教训：pdfrx `PdfImage` dispose 后 width/height 不可再用；path_provider 无同步目录 API
