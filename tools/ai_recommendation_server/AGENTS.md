本目录是已部署的 AI 精选后端。操作前阅读 README.md。

- 用户要求更新服务器服务时，默认 SSH 目标为 root@60.204.209.218，身份文件为用户目录下 .ssh/id_ed25519。
- 修改后运行已有 checks.py 和 server_checks.py；部署脚本也会在服务器运行这两组检查。
- 将需要部署的代码提交到当前 AI 功能分支，然后从仓库根目录执行 tools/ai_recommendation_server/deploy.ps1。
- deploy.ps1 只上传当前 HEAD 的已提交内容。成功后检查 API 健康及 systemd 状态。
- 保留 /opt/piliplus-ai/.env、/var/lib/piliplus-ai 的配置与历史，以及已有 Nginx 和 TLS 配置。
- 不得将 API Key、B 站 Cookie、签名密钥、feed-path 或私有清单提交到 GitHub，也不要在日志里输出凭据。
- 没有 AI 密钥和 Cookie 时只能验证部署与接口，不能声称真实 AI 清单已经生成。
- 安装包发布依赖 GitHub Actions，检查实际构建和 Release 后再报告成功。
