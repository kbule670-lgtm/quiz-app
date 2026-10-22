# 刷题 App · 工程说明

给朋友做的刷题 App：可导入题库 → 四选一单选 → 做对过、做错进错题本重做。
这台 Linux 编不出 ipa，所以交付完整 Xcode 工程源码，他在 Mac 上打包。

## 在 Mac 上跑起来（5 分钟）

1. Mac 上装 Xcode（App Store 免费下），新建工程：iOS → App，
   Interface 选 SwiftUI，Language 选 Swift，把这 11 个 `.swift` 文件拖进去（勾选 Copy）
2. Deployment Target 设 iOS 17.0（用了 SwiftData）
3. 点 Run（⌘R），先在模拟器里跑通最小闭环：
   题库页 → 载入内置示例题 → 刷题（故意答错几道）→ 错题本 → 重做移出

## 打成 ipa 发给她

1. Xcode 顶部把目标从模拟器切换成 **Any iOS Device (arm64)**
2. 菜单 Product → Archive，等编译完弹出 Organizer
3. Distribute App → **Ad Hoc**（或 Development）→ 选他自己的签名证书 → Export
4. 得到 `.ipa`，发给她用爱思助手 / 自签工具安装

注：免费 Apple ID 签名 7 天有效、最多装 3 个自签 App，过期重签就行。

## 文件导览（每文件一句话）

- `QuizApp.swift` — App 入口，搭 SwiftData 容器
- `Models/Question.swift` — 一道题的数据模型：题干/4选项/答案/解析 + 刷题统计；
  错题本 = "答错过、还没连续答对 N 次"的题。`requiredStreak` 改 1→2 就是"对两次才移出"
- `Services/QuestionImporter.swift` — 题库导入：JSON、CSV、文字版三种解析，答案写 A/B/C/D；文字版认题号+A-D选项+「答案：B」
- `Services/DocumentImporter.swift` — 从 PDF（PDFKit）/ .docx（解 zip 取 document.xml 剥标签，靠 ZIPFoundation）里提取文字，再走文字版解析；扫描版 PDF、老版 .doc 会明确报错
- `Services/SampleBank.swift` — 内置 5 道示例题，跑通流程后可删
- `ViewModels/QuizSession.swift` — 一次刷题会话：顺序/随机、判分、写统计
- `Views/ContentView.swift` — 首页三 Tab：刷题 / 错题本 / 题库
- `Views/QuizView.swift` — 刷题页：一题一屏，答错标红+给解析
- `Views/WrongBankView.swift` — 错题本列表 + 一键重做
- `Views/GlassStyle.swift` — 液态玻璃适配：iOS 26+ 主按钮/选项走真玻璃，旧系统自动回退（需 Xcode 26 编译，云端流程已配好）
- `Views/ImportView.swift` — 题库页：文件导入 / 示例题 / 导出 JSON / 清空

## 已知事项（周五在 Mac 上验证）

- 代码是在 Linux 上写的，没经过 Xcode 编译；大概率能直接跑，
  万一有小报错，把报错信息贴给我，我来修
- v1 范围：只做四选一单选 + 顺序/随机 + 错题本 + 导入导出；考试模式 v2 再加
- 导入认 JSON 和 CSV（Excel 另存为 CSV 就行）；App 内手动录题 v1 没做，要加的话说一声
