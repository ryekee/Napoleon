# Napoleon 项目约束

## 沟通与验证

- 默认使用中文。区分源码修改、测试通过、实际运行、界面验收和公开发布，不互相代替。
- 保留用户未提交的改动。未获明确授权，不提交、推送或发布。

## 本地构建与签名

- 默认通过 `./script/build_and_run.sh --verify` 构建、验证签名并替换运行实例。
- `project.yml` 是构建配置事实源；修改后通过 XcodeGen 重新生成工程，不能只改生成的 `.xcodeproj`。
- 本地 Debug 验收必须沿用已安装正式版的 Developer ID 身份：
  `Developer ID Application: Shenzhen Hiko Technology Co., Ltd. (JQTFJ8P2T7)`，
  Bundle ID 为 `com.napoleon.Napoleon`。不允许静默改用 `com.ryekee.napoleon` 自签名、Apple Development、ad hoc 或无签名。
- 构建后必须验证签名有效性，并确认产物满足 `/Applications/Napoleon.app` 的 designated requirement（若安装版存在）。仅 Bundle ID 相同或“已经签名”不足以证明权限可沿用。
- 签名证书或私钥不可用、身份检查失败时，保留现有运行实例，报告具体原因；不要通过降级签名、重置 TCC 或要求用户重新授权来绕过问题。
- 签名验证通过后再停止旧实例并启动新产物，核对实际进程路径。不得因编译成功就声称新版本已经运行。
- 签名一致不等于权限已经验证。分别检查辅助功能与屏幕录制权限；无法读取时明确报告未验证，不承诺无需重新授权。
- 本地重建不等于发布；不自动覆盖 `/Applications` 安装版，不自动公证或上传。
