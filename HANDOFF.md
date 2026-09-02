# HANDOFF — AgentBookReader 交接文档

> 接手前必读。代码可运行、测试全绿（42 个）。已提交并推送到 GitHub：https://github.com/Dashi929/AgentBookReader（main 分支）。

## 一、项目概况

- **是什么**：跨平台电子书阅读器（Android/iOS/Windows/Linux），内置 AI Agent（对话问答、批注、改写提案）与翻译（整页/选块，多提供方）
- **路径**：`D:\Projects\AgentBookReader`（包名 `agent_book_reader`，org `com.openleaf`）
- **技术栈**：Flutter 3.47.2 / Dart 3.13.2 · Riverpod · drift(SQLite) · http · file_selector · enough_convert · flutter_secure_storage
- **规模**：40 个 dart 文件 / ~7000 行 / 34 个自动化测试
- **Git**：已 init、**零提交**（用户规矩：他说"提交/推送"才能动）。远程未配置
- **运行产物**：`build\windows\x64\runner\Release\agent_book_reader.exe`

## 二、环境（每次会话第一步）

```powershell
$env:Path += ';D:\dev\flutter\bin'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
```
- Flutter 装在 `D:\dev\flutter`（用户级 PATH 已配）
- Windows 桌面构建需 VS 2026 C++ 工作负载（已装）+ **系统开发者模式**（已开，注册表 AppModelUnlock\AllowDevelopmentWithoutDevLicense=1）
- iOS 不能在 Windows 构建；Android SDK 有但 licenses 未接受

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
                           # edit_section_screen(编辑/导出) agent_settings_screen(LLM 配置)
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
flutter run -d windows            # 调试
flutter run -d chrome             # Web 调试（需 flutter create . --platforms web，已配）
dart run build_runner build --delete-conflicting-outputs   # drift 改表后必须跑
flutter gen-l10n                  # ARB 改后必须跑（或 flutter run 自动）
```
