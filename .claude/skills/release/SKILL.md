---
name: release
description: 为 Napoleon 构建、签名、公证和验证正式 macOS 分发包。
---

# Napoleon Release

1. 阅读 `RELEASING.md` 与 `project.yml`，确认版本号和工作树状态。
2. 验证 Developer ID 身份与 `Hiko-notray`，不得读取、复制或提交 `.p8`。
3. 执行 `script/package_release.sh`。签名必须由内到外，不用 `codesign --deep` 代替递归签名。
4. 公证等待上限为 30 分钟。超时后保留 Submission ID，以 `--resume` 继续，禁止重复提交。
5. 仅在 Accepted、staple、Gatekeeper 和 SHA-256 验证全部通过后，才把 DMG 视为发布候选。
6. 未经用户明确确认，不创建、上传或公开 GitHub Release。

Debug 继续使用 `com.ryekee.napoleon` 自签名身份以维持本机 TCC；正式 Release 使用 Team `JQTFJ8P2T7` 的 Developer ID。不要开启 App Sandbox，也不要引入 Sparkle。
