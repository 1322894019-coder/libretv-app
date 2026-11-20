# LibreTV iOS 客户端

基于系统 WKWebView 的非官方自用客户端，影视搜索与播放由你自己部署的 LibreTV 服务提供。

## 功能

- 保留原 LibreTV 应用 LOGO。
- 支持局域网直连（手机与电脑同一网络）。
- 支持 IPv6 直连（两端网络均支持 IPv6，且家庭网关未拦截入站）。
- 启动时自动检测所有线路延迟，设置页逐条显示具体延迟（毫秒）。
- 最快可用线路自动置顶并推荐连接；公网中转（ngrok / Tailscale）作为兜底。
- 支持手动填写自定义服务器地址，地址仅保存在本机。

## 构建

未签名 IPA 由 GitHub Actions 在 macOS 上构建（见 `.github/workflows/build-ipa.yml`），产物为 arm64 物理设备包，安装前需用自己的 Apple 账号签名。
