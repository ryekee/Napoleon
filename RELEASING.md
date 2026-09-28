# Napoleon 发布与 Apple 公证

Napoleon 的正式分发包使用以下固定身份：

- Team ID：`JQTFJ8P2T7`
- Developer ID：`Developer ID Application: Shenzhen Hiko Technology Co., Ltd. (JQTFJ8P2T7)`
- 公证钥匙串 profile：`Hiko-notray`
- Bundle ID：`com.napoleon.Napoleon`

`Hiko-notray` 保存 Hiko 开发团队的 App Store Connect API 凭据，不绑定具体 App 的 Bundle ID，因此同一团队的 App 可以复用。不要把 API Key、`.p8`、证书私钥或钥匙串内容放进仓库。

## 发布

先更新 `project.yml` 中的 `CFBundleShortVersionString`，然后运行：

```bash
script/package_release.sh
```

脚本会依次执行通用 Release 构建、由内到外的 Developer ID 签名、Hardened Runtime/timestamp 验证、DMG 制作与签名、公证、staple、Gatekeeper 验证和 SHA-256 计算。它不会创建或上传 GitHub Release。

若 30 分钟后仍为 `In Progress`，脚本以状态码 2 退出并保留 Submission ID。不要重新提交同一 DMG，使用：

```bash
script/package_release.sh --resume <submission-id>
```

只有 profile 丢失、钥匙串被重置或更换 Mac 时，才重新执行 `notarytool store-credentials`。日常发版不需要 `.p8`。

脚本会在封装 DMG 前校验临时 App 及全部嵌套代码。最终上传前再确认：

```bash
xcrun stapler validate build/dist/Napoleon-<version>.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 build/dist/Napoleon-<version>.dmg
shasum -a 256 build/dist/Napoleon-<version>.dmg
```

## 更新清单

公证与 Gatekeeper 验证成功后，脚本生成 `build/dist/update.json`（包括 resume 成功路径）。
将它与对应版本 DMG 一起上传到同一个 GitHub Release；建议先在 draft 中上传齐全，再发布为最新正式版。
清单格式为 `{"schemaVersion":1,"version":"0.3.2","notes":""}`，可在上传前填写纯文本 notes。
version 必须与该 Release 的 `v<version>` tag 和 DMG 版本一致；更新检查仅接受数字正式版本，不接受 beta。

客户端读取 `https://github.com/ryekee/Napoleon/releases/latest/download/update.json`，不调用 REST API。
清单返回 404 时，兼容历史 Release：以 HEAD 请求读取 `releases/latest` 最终跳转的正式版 tag。
其他 HTTP 错误或清单损坏均明确报错，不误报“已是最新”。兼容路径不提供内嵌更新说明，用户仍可打开 Release 页面。
