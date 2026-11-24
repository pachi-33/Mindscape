# Mindscape 发布与升级

自动更新目录为 `https://raw.githubusercontent.com/pachi-33/Mindscape/main/updates/appcast.xml`，更新 ZIP 由 [自有仓库 Releases](https://github.com/pachi-33/Mindscape/releases) 提供。旧客户端要先从该发布页手动安装一次带新更新器的版本。过渡版沿用应用标识及现有文稿库。

## 正式发布

发布机需要 Xcode、XcodeGen、Python 3、已登录的 GitHub CLI、Developer ID Application 签名身份和已配置的 `notarytool` 钥匙串配置。用 Sparkle 官方同版本的 `generate_keys --account <专用账户>` 初始化发布签名密钥。将私钥保存在受控签名环境中。后续版本使用同一更新密钥。

1. 在 `project.yml` 提升 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，并添加对应的 `CHANGELOG.md` 条目。构建号须高于所有已发布构建，面向用户的版本号须高于同通道的前一版。带预发布后缀的版本会进入 beta 通道。
2. 合入并验证 CI 后，从干净的 checkout 运行下列命令。签名脚本将检查本地和远端 `main` 是否匹配。

   ```sh
   RELEASE_COMMIT="$(git rev-parse HEAD)" \
   RELEASE_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
   RELEASE_TEAM='YOURTEAMID' NOTARY_PROFILE='mindscape-notary' \
   SPARKLE_ACCOUNT='mindscape-release' make publish
   ```

3. 脚本会生成通用应用、签名并公证，打包 ZIP 与手动安装用的 DMG。它会在自有仓库上传草稿，下载草稿附件与本地签名包逐字节比较，再发布 Release。只有确认公开地址提供完全相同的文件后，才把已经签名的目录写入 `updates/appcast.xml`。
4. 将生成的目录原样提交并合入 `main`，客户端即可发现新版本。目录包含既有发布条目，稳定版仍能取得正式发布。不得手工编辑签名后的 XML。若公开下载或远端提交检查失败，旧目录仍有效。核对 `dist/release.*` 内生成的签名目录和已发布附件再继续。

普通本地构建可以不带发布公钥。这类构建运行编辑功能，但无法使用正式更新源安装包。用临时密钥验收时，应使用独立的 bundle ID、回环目录和隔离文稿库。正式发布前需在目标签名环境验证公证包能安装以及自动更新。

## 问题版本

先从目录撤下有问题的条目并重新签名，可以停止向尚未升级的用户提供它。已经升级的用户应通过更高版本和构建号的修复包恢复。
