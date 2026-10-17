# 安全政策

## 回報安全問題

如果你發現這個專案的安全問題（例如更新機制可被繞過、密鑰可能外洩），請**不要**直接開公開的 Issue。
請使用 GitHub 的 **Security → Report a vulnerability**（私下回報）。

請盡量附上：影響範圍、重現步驟、你使用的版本。收到後會盡快回覆。

## 範圍

- Mac App（`IGPubApp`）與命令列工具（`igpub`）。
- 自動更新機制：下載、驗證、安裝。
- 不在範圍：Instagram、Meta、Cloudflare 本身的問題，請向它們回報。

## 你可以自己確認的事

- 下載後用 `codesign -dr - /Applications/img_to_ig.app` 確認 `certificate leaf` 與 README 列出的一致。
- App 只會連線到 `graph.instagram.com`、你自己的儲存空間、`api.github.com` 與 `github.com`。
- 權杖與金鑰只存在 macOS 鑰匙圈，不會寫進檔案或 git。

## 如果簽章憑證外洩或遺失

簽章憑證（`img_to_ig Release Signing`）的私鑰只放在作者的登入鑰匙圈。若外洩，惡意人士可以簽出會被
自動更新接受的版本；若遺失，之後簽的版本會被視為不同身分。兩種情況都會公告，並要求使用者手動重新安裝
新簽章的版本。
