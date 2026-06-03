# 3X-UI (优化 & 汉化分支)

本项目是基于原始 [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) 二次开发与加固的优化分支，专为中文用户设计，深度定制并加固了 SSL 证书申请流程，同时实现了安装、更新和 CLI 管理脚本的完全汉化。

本分支代码已部署并维护于 GitHub 仓库：**[lgdglgc/3x-ui](https://github.com/lgdglgc/3x-ui)**

---

## 🌟 主要改动与优化 (Change Logs)

### 1. 深度中文汉化 (Chinese Localization)
为解决原版安装及命令行管理界面全英文对中文用户不够友好的问题，我们对核心 Shell 脚本进行了全面、标准的中文本地化：
- **CLI 管理菜单汉化**：重写了 `x-ui.sh` 中的命令行菜单（含 28 项主菜单及各项子设置），全部汉化为简洁规范的中文。
- **命令行使用指南汉化**：汉化了快捷子命令说明框（`show_usage`），包括启动、停止、重启、查看日志等操作。
- **安装与更新引导汉化**：无论是首次运行 `install.sh` 还是通过 `update.sh` 进行版本升级，整个交互引导过程（包括 SQLite/PostgreSQL 数据库选择、随机凭证/随机端口生成、自定义配置确认等）均提供完整的中文字符界面，对齐美观。

### 2. SSL 证书申请流程极致优化 (SSL Issuance Hardening)
针对 acme 申请 SSL 证书时频发的失败问题，我们设计并集成了一套防冲突、防锁频、高容错的申请机制：
- **下载源自动容灾（`ghproxy`）**：检测并支持在 `acme.sh` 官方安装源连接超时或受阻时，自动无缝切换至国内加速镜像源，确保 100% 成功部署 acme 客户端。
- **DNS 解析预校验**：在调用 acme.sh 申请证书前，脚本会自动比对您域名的公网解析 IP 是否与当前服务器 IP 一致。若不一致或解析未生效，将弹出警告并提示您确认，有效避免因配置错误频繁申请导致被 CA 封锁。
- **端口冲突 & 占用自动处理**：验证端口（80/自定义端口）如果被 Nginx、Caddy、Apache2 等服务占用，脚本将临时停止这些服务，并在验证完成后自动恢复。
- **防火墙端口智能放行**：申请时临时在 UFW、Firewalld 或 iptables 防火墙中开放验证端口，申请完毕后自动闭合。
- **100% 恢复保障（Trap 机制）**：引入系统信号捕获（Trap），**无论证书申请成功、失败还是您中途按 Ctrl+C 中断，脚本都能保证将防火墙规则和被占用的 Web 服务完璧归赵**，不影响您服务器上的现有业务。
- **ZeroSSL 备用 CA 灾备**：若 Let's Encrypt 遇到申请限制或服务器宕机，脚本会自动 fallback 切换到 ZeroSSL 并绑定账户，提供双重保险。
- **IPv6 双栈智能感知**：仅在服务器拥有 IPv6 且域名解析有 AAAA 记录时才启用 `--listen-v6` 监听，防止单栈环境下报错。

---

## 🚀 快速开始 (Quick Start)

### 一键安装 (Install)
在您的服务器终端运行以下命令进行全新汉化版安装：
```bash
bash <(curl -Ls https://raw.githubusercontent.com/lgdglgc/3x-ui/main/install.sh)
```

### 一键更新 (Update)
若要更新已安装的面板，同时保留现有配置和数据：
```bash
bash <(curl -Ls https://raw.githubusercontent.com/lgdglgc/3x-ui/main/update.sh)
```

### 命令行管理面板
安装完成后，在终端直接输入 `x-ui` 即可呼出全中文管理菜单：
```bash
x-ui
```

---

## 🛠️ 支持的命令及子命令

在命令行中，您可以直接使用 `x-ui` 加子命令快速执行操作：

```
┌────────────────────────────────────────────────────────────────┐
│  x-ui 控制菜单使用方法 (命令行子命令):                         │
│                                                                │
│  x-ui                       - 显示管理菜单 (管理脚本)          │
│  x-ui start                 - 启动 x-ui 面板                   │
│  x-ui stop                  - 停止 x-ui 面板                   │
│  x-ui restart               - 重启 x-ui 面板                   │
│  x-ui status                - 查看当前状态                     │
│  x-ui settings              - 查看当前设置                     │
│  x-ui enable                - 启用面板开机自启                 │
│  x-ui disable               - 禁用面板开机自启                 │
│  x-ui log                   - 查看面板运行日志                 │
│  x-ui banlog                - 查看 Fail2ban 封禁日志           │
│  x-ui update                - 更新 x-ui 面板                   │
│  x-ui legacy                - 切换历史版本                     │
│  x-ui install               - 安装 x-ui 面板                   │
│  x-ui uninstall             - 卸载 x-ui 面板                   │
└────────────────────────────────────────────────────────────────┘
```

---

## 🤝 致谢与引用 (Credits)

- 本项目源自官方优秀的开源项目：[MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui)
- 感谢原版作者及所有社区贡献者。本优化分支完全遵循开源精神进行发布与维护。
