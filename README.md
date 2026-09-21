# 3X-UI (定制汉化 & 稳定加固版)

<p align="center">
  <strong>专为中文用户与生产环境打造的高性能、全本地化 Xray 可视化管理面板</strong><br>
  <sub>全中文交互 ｜ 生产级加固 ｜ 核心版本锁定 ｜ AI 专属家宽分流 ｜ BBR v3 & 智能调优 ｜ 纯净自托管</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Panel_Version-3.8.5-blue?style=flat-square" alt="Panel Version" />
  <img src="https://img.shields.io/badge/Xray_Core-v26.6.27_(LTS)-success?style=flat-square" alt="Xray Core Version" />
  <img src="https://img.shields.io/badge/TCP_BBR-v3_%26_Smart_Tuning-blueviolet?style=flat-square" alt="TCP BBR" />
  <img src="https://img.shields.io/badge/Language-简体中文-red?style=flat-square" alt="Language" />
  <img src="https://img.shields.io/badge/License-GPL--3.0-orange?style=flat-square" alt="License" />
</p>

> **项目定位**：本项目基于官方知名上游 `MHSanaei/3x-ui` 深度二次开发，专为中文用户与高可用生产环境量身定制。彻底解决原版常见的**语言割裂、一更新就变英文、新内核协议解析报错、80 端口占用导致 SSL 申请失败、AI 服务频繁拦截与验证码、节点体检跑测速跑爆流量、缺乏专业网络加速**等诸多实战痛点。

### 🔥 核心优化全景对比（定制加固版 vs 官方原版）

| 核心维度 | 官方原版 (`MHSanaei/3x-ui`) | 本项目深度优化与加固版 (`lgdglgc/3x-ui`) |
| :--- | :--- | :--- |
| **🌐 AI 专属分流生态** | 仅依赖普通规则，ChatGPT/Claude/Gemini 等极易遭遇风控拦截 | **内置专属 `geosite_myai.dat`**（覆盖 240 条海外全生态 AI、WebRTC 语音端点；彻底排除国产 AI 直连与大模型下载，防止跑爆家宽流量） |
| **🔍 纯 IP 质量与体检** | 缺乏专用规则，节点体检时容易误触发测速跑爆昂贵流量 | **内置专属 `geosite_ping.dat`**（深度收录 `ping0.cc`、`scamalytics`、`ipqualityscore`、`whoer`、`incolumitas` 等 308 条规则，严格排除测速站，0 流量损耗） |
| **⚡ 网络底层与 BBR 加速** | 仅提供简易 sysctl 两行命令，无内核管理 | **深度集成 BBR v3 主线内核一键管理** + 亚太/跨国高延迟优化 + 多队列算法热切 (`FQ`/`CAKE`/`FQ-CoDel`) + 智能带宽缓冲区计算 + 极限测速挑战模式 |
| **🛡️ Xray 核心版本策略** | 盲目跟进高版本，易导致 Clash Meta / Sing-box 客户端配置解析报错 | **锁定 LTS 黄金稳定内核 (`v26.6.27`)**，避开新版协议 Bug，保证全生态客户端即连即用、无感知穿透 |
| **🔒 SSL 证书自动化** | 80 端口被占直接报错退出，频繁重试易触发 CA 限额 | **智能接管冲突服务**（自动探测并暂挂 Nginx/Apache/Caddy/OpenResty 等并 100% 恢复） + DNS 解析预校验 + ZeroSSL 自动灾备 |
| **🇨🇳 界面汉化与纯净度** | 英文为主，中文翻译生硬残缺，Go 后端控制台全英文日志 | **300+ 处全链路深度汉化**（安装、更新、CLI 交互、报错告警、Go 后端控制台日志全中文），彻底剥离原版内置广告与外部群组弹窗 |
| **🔄 更新闭环与防回退** | 一更新管理脚本或面板即被官方英文覆盖，打回原形 | **双向脚本同步与面板二进制更新重定向打补丁**，后续无论是命令行还是后台点击更新，终身锁定中文稳定版 |

---

## 📑 目录

- [核心优化全景对比](#-核心优化全景对比定制加固版-vs-官方原版)
- [版本规范与设计原则](#-版本规范与设计原则)
- [快速开始 (一键部署与维护)](#-快速开始)
  - [一键全新安装](#1-一键全新安装-install)
  - [一键无损更新](#2-一键无损更新-update)
  - [全中文管理菜单一键修复](#3-全中文管理菜单一键修复-restore-menu)
  - [专属规则库一键拉取 (AI 规则 / 纯 IP 质量规则)](#4-专属分流规则库一键拉取-pull-dat-rules)
  - [终端呼出管理菜单](#5-终端呼出管理菜单)
- [主要优化与核心特性](#-主要优化与核心特性)
  - [1. 专属 AI 分流规则库 (geosite_myai.dat)](#1-专属-ai-分流规则库-geosite_myaidat)
  - [2. 纯 IP 质量与欺诈分检测规则库 (geosite_ping.dat)](#2-纯-ip-质量与欺诈分检测规则库-geosite_pingdat)
  - [3. 深度中文汉化与纯净体验](#3-深度中文汉化与纯净体验)
  - [4. Xray 内核版本加固与客户端兼容](#4-xray-内核版本加固与客户端兼容)
  - [5. 生产级 SSL 证书申请与端口容灾](#5-生产级-ssl-证书申请与端口容灾)
  - [6. 防英文覆盖的更新闭环机制](#6-防英文覆盖的更新闭环机制)
  - [7. BBR 网络加速与内核管理体系 (BBR v3 / 智能调优)](#7-bbr-网络加速与内核管理体系-bbr-v3--智能调优)
- [终端管理菜单总览](#-终端管理菜单总览)
- [命令行子命令速查](#-命令行子命令速查)
- [常见问题与实战指南 (FAQ)](#-常见问题与实战指南-faq)

---

## 🎯 版本规范与设计原则

本项目基于官方上游优秀架构，深度解决实际运维中常见的**语言割裂、版本混乱、新内核兼容性崩坏、证书申请端口冲突、AI 服务频繁拦截**等痛点：

| 组件 / 特性 | 预设配置 | 说明 |
| :--- | :--- | :--- |
| **上游 Release 渠道** | `MHSanaei/3x-ui` 官方发行源 | 安装包直接拉取官方发布归档，确保核心二进制完整可靠 |
| **默认面板版本** | **`3.8.5`** | 锁定当前功能最完备、经实测最稳定的面板版本 |
| **默认 Xray 内核** | **`v26.6.27`** | 锁定黄金稳定版内核，避开新版协议解析 Bug，完美兼容全平台客户端 |
| **AI 路由规则库** | **`geosite_myai.dat`** | 原生预装，主流 AI（ChatGPT/Claude/Gemini 等）一键分流至住宅/解锁节点 |
| **IP 质量诊断库** | **`geosite_ping.dat`** | 原生预装，纯 IP 质量/欺诈分/Ping 诊断（严格剔除测速站，0 流量损耗） |
| **网络加速体系** | **BBR v3 + 智能 TCP 调优** | 双层加速体系：通用免换内核 BBR/队列热切 + Debian/Ubuntu 专属 BBR v3 主线内核管理 |
| **交互式确认** | 支持一键回车部署 | 安装、更新及版本切换均提供默认推荐值，直接按回车即可极速部署 |

---

## 🚀 快速开始

### 1. 一键全新安装 (Install)
全新服务器推荐直接执行以下一键安装命令：
```bash
bash <(curl -Ls https://raw.githubusercontent.com/lgdglgc/3x-ui/main/install.sh)
```
> **提示**：安装过程中提示选择版本时，直接回车即可部署推荐的 `3.8.5` 面板与 `v26.6.27` Xray 核心。

### 2. 一键无损更新 (Update)
若需要更新已有面板，且完整保留所有节点、证书与配置数据：
```bash
bash <(curl -Ls https://raw.githubusercontent.com/lgdglgc/3x-ui/main/update.sh)
```

### 3. 全中文管理菜单一键修复 (Restore Menu)
如果您的终端管理菜单之前意外变回了官方英文原版，粘贴以下命令即可一键恢复全中文：
```bash
curl -fLRo /usr/bin/x-ui https://raw.githubusercontent.com/lgdglgc/3x-ui/main/x-ui.sh && cp -f /usr/bin/x-ui /usr/local/x-ui/x-ui.sh && chmod +x /usr/bin/x-ui /usr/local/x-ui/x-ui.sh
```

### 4. 专属分流规则库一键拉取 (Pull Dat Rules)

#### (1) AI 专属分流规则库 (`geosite_myai.dat`)
当发现有新出的 AI 独立域名或本项目云端规则更新时，执行以下命令即可一键拉取最新规则并自动平滑重启生效：
```bash
curl -fLRo /usr/local/x-ui/bin/geosite_myai.dat https://raw.githubusercontent.com/lgdglgc/3x-ui/main/geosite_myai.dat && systemctl restart x-ui
```

#### (2) 纯 IP 质量 / 欺诈分 / Ping 诊断规则库 (`geosite_ping.dat`)
专用于出口节点纯净度体检（如 `ping0.cc`、`scamalytics.com`、`ipqualityscore.com`、`whoer.net` 等），**已严格过滤排除所有测速网站**，防止跑测速跑爆流量：
```bash
curl -fLRo /usr/local/x-ui/bin/geosite_ping.dat https://raw.githubusercontent.com/lgdglgc/3x-ui/main/geosite_ping.dat && systemctl restart x-ui
```
> **提示**：也可以在终端直接执行 `x-ui update-all-geofiles` 一键更新包括 `geosite_myai.dat` 与 `geosite_ping.dat` 在内的全部规则文件。

### 5. 终端呼出管理菜单
安装或修复后，在终端随时输入以下命令即可打开控制面板菜单：
```bash
x-ui
```

---

## 🌟 主要优化与核心特性

### 1. 专属 AI 分流规则库 (`geosite_myai.dat`)
为了解决自建节点访问 OpenAI / Claude / Gemini / Antigravity 经常遭遇 IP 限制、验证码弹窗或住宅 IP 家宽路由需求，本项目直接内置专用的 AI 规则数据库并实施严格的分流防坑策略：

- **全场景生态覆盖（网页端、桌面端、IDE、API网关）**：
  - **主流商业与对话 AI**：`OpenAI / ChatGPT`（补全 WebRTC 实时语音端点 `*.livekit.cloud` 与灰度接口 `featuregates.org`、`statsig.com`）、`Anthropic (Claude)`、`Google (Gemini / DeepMind / AI Studio / Vertex AI / NotebookLM / Jules / Labs / Antigravity 全生态)`、`Microsoft (Copilot)`、`Meta AI (Llama / meta.ai)`、`Perplexity`、`Grok (xAI)`、`Poe`、`DuckDuckGo AI (duck.ai)`、`Coze (coze.com)`、`Cici AI (cici.com)`。
  - **AI IDE 与编程插件桌面端**：`Antigravity IDE`（全套代码流与沙箱通道）、`Cursor`（包含 blob 与 assets 存储）、`Windsurf (Codeium)`（含核心底层 `exafunction.com`）、`JetBrains AI (Grazie / grazie.ai)`、`Trae AI (字节海外版 / trae.ai)`、`MarsCode (marscode.com)`、`CodeRabbit (AI Code Review)`、`Qoder`、`Continue.dev`、`Supermaven`、`Augment Code`、`Zed`。
  - **知名 AI 独立客户端与 Agent 协作体系**：`Notion AI`（`notion.so` / `notion.com`）、`Raycast AI`（含 `backend.raycast.com`）、`Chatbox`、`Cherry Studio`、`Jan`、`LobeChat`、`ClawHub / OpenClaw`、`Agent Client Protocol (ACP)`、`DeepWiki` 等。
  - **主流云端推理与聚合 API 网关**：`OpenRouter`、`Groq`、`Together AI`、`Fireworks AI`、`DeepInfra`、`Mistral AI / Le Chat`、`Cohere`、`Fal.ai`、`Replicate`、`Cloudflare AI Gateway (gateway.ai.cloudflare.com)`、`Chutes AI`、`H2O.ai`。
  - **音视频、多模态与生图工作流**：`ElevenLabs`、`Midjourney`、`ComfyUI (comfy.org / comfyregistry.org)`、`NovelAI`、`HeyGen`、`Descript`、`Otter.ai`、`Suno`、`Udio`、`Runway`、`Luma`、`Pika`、`NoteGPT` 等。
- **🚫 严防国产 AI 误入家宽**：已彻底剔除 DeepSeek、Kimi、通义千问等纯国内 AI 服务。国内服务默认走直连（Direct），享受毫秒级极速响应，规避因绕行海外住宅 IP 引发的严重延迟与平台风控封号。
- **📦 大文件/模型站流量隔离**：像 HuggingFace (`huggingface.co`)、Civitai 动辄数 GB ~ 几十 GB 的模型权重下载，默认**不并入** `ai` 家宽列表，防止瞬间跑爆昂贵的家宽限额或拥塞上行带宽；如有需要，可使用独立标签 `ext:geosite_myai.dat:huggingface` 单独分流。
- **⚠️ 关键网络配置（支持语音模式）**：在 3X-UI 面板配置 AI 路由规则时，**网络协议（Network）务必留空或选择 `tcp,udp`**，切勿仅勾选 `tcp`，否则 ChatGPT 高级实时语音模式（WebRTC 依赖 UDP）将无法接通。
- **全链路自动部署**：`install.sh` 与 `update.sh` 在安装或更新时，自动将 `geosite_myai.dat` 下载并配置到 `/usr/local/x-ui/bin/`。

```
┌─────────────────────────────────────────────────────────────────┐
│                    3X-UI 生产级流量路由架构                     │
│                                                                 │
│  客户端流量 ──► [ Xray 路由引擎 ]                                │
│                      │                                          │
│                      ├─► 命中 geosite_myai.dat:ai ────────────► [AI 家宽/解锁出口 (TCP+UDP)] │
│                      │   (ChatGPT/Claude/Gemini/Antigravity...) │
│                      │                                          │
│                      ├─► 命中 geosite:cn / geoip:cn ──────────► [直连 Direct]                │
│                      │   (DeepSeek/Kimi/国内常规流量)           │
│                      │                                          │
│                      └─► 默认外网流量 ────────────────────────► [主力 VPS 出口]             │
└─────────────────────────────────────────────────────────────────┘
```

### 2. 纯 IP 质量与欺诈分检测规则库 (`geosite_ping.dat`)
专为**节点纯净度体检、欺诈分（Fraud Score）测定、伪装度分析与网络延迟诊断**量身打造的轻量级规则库：
- **🚫 严格剔除测速大流量网站**：彻底排除 `speedtest.net`、`fast.com`、`nperf.com`、`librespeed.org` 等瞬时耗费上百兆流量的带宽测试平台，**彻底杜绝因测速跑爆昂贵的家宽限额或 VPS 流量**。
- **🎯 深度收录权威纯净度与欺诈分平台**：全面补齐 `ping0.cc`、`scamalytics.com`（权威风控欺诈分）、`ipqualityscore.com`（IPQS 企业级风控）、`whoer.net`（伪装度 100% 测试）、`browserleaks.com`（WebRTC/指纹防泄漏）、`pixelscan.net` 等。
- **📡 网络连通性与 Ping 诊断**：收录 `ping.pe`、`ping.sx`、`itdog.cn`、`tcping.cn`、`check-host.net` 等常用跨国延迟与端口可达性探测端点。
- **🌐 官方兼容与细分 Tag 支持**：全面整合 MetaCubeX 官方 `category-ip-geo-detect`（238 个海外与国内 IP 探测 API），并提供 `ext:geosite_ping.dat:ping`、`ext:geosite_ping.dat:fraud`、`ext:geosite_ping.dat:leak`、`ext:geosite_ping.dat:ping-tools` 等灵活标签。

### 3. 深度中文汉化与纯净体验
- **300+ 处交互提示全量精翻**：从安装脚本提示、报错告警，到终端交互式菜单、配置重置提示，均以纯正规范的中文表达呈现。
- **Go 后端控制台日志汉化**：全面汉化 `main.go` 命令行参数帮助（`-help` / `-v` / `-reset` 等）、数据库迁移升级、端口监听及两步验证重置日志。
- **环境默认适配**：默认界面语言与 Telegram 消息模板固定为 `zh-CN`，系统默认时区调整为 `Asia/Shanghai`。
- **独立纯净无外链**：彻底剥离上游项目广告、外链赞助入口（Donate）及外部 Telegram 群组弹窗，适合生产及自托管使用。

### 4. Xray 内核版本加固与客户端兼容
- **锁定 LTS 稳定内核 (`v26.6.27`)**：
  实测表明，Xray 在升级至 `v26.7.x` ~ `v26.9.x` 过程中曾引入部分新协议变更与配置结构调整，易导致配置解析失败或引发 **Clash Meta (Mihomo) / Clash Verge / Sing-box / Shadowrocket** 等客户端兼容性异常。
- 本项目锁定经大量生产验证最稳固的 `v26.6.27` 为推荐版本，安装脚本中限制误升级，确保全生态客户端即连即用、无感知穿透。

### 5. 生产级 SSL 证书申请与端口容灾
对 `acme.sh` 独立证书申请流程做了全面加固：
- **80 端口占用智能检测与优雅停止**：申请证书时，自动探测并临时挂起占用 80 端口的 Web 服务（支持 **Nginx、OpenResty、Apache2、Httpd、Caddy、Tengine**）。
- **占用进程强制释放**：检测到顽固进程占用端口时，支持用户选择自动调用 `fuser` 强制释放端口，确保验证服务正常启动。
- **DNS 解析预校验**：申请前自动比对域名解析 IP 与本机公网 IP，避免因解析未生效频繁重试导致被 Let's Encrypt 官方暂时封锁。
- **100% 状态恢复保障 (Trap 机制)**：无论是证书申请成功、验证失败还是中途被 `Ctrl + C` 中断，脚本都能确保将系统防火墙规则及被暂停的 Web 服务完全恢复原状。
- **ZeroSSL 自动灾备**：当 Let's Encrypt CA 故障或达到限额时，脚本自动平滑切换至 ZeroSSL 备用 CA 申请。

### 6. 防英文覆盖的更新闭环机制
针对原版“一更新面板管理脚本就变回英文”的顽疾，本项目做了全链路防覆盖机制：
- **本地脚本双向同步**：更新和安装时，同步更新 `/usr/bin/x-ui` 与 `/usr/local/x-ui/x-ui.sh`，防止解压上游压缩包时原版英文脚本残留。
- **二进制更新调用重定向**：安装时自动对面板二进制的后台更新接口打补丁，即便通过 Web 后台点击【更新面板】，也会请求定制汉化源，彻底告别英文回退。

### 7. BBR 网络加速与内核管理体系 (BBR v3 / 智能调优)
告别传统脚本简单的两行 sysctl 开启方式，本项目深度重构并集成了企业级 **BBR 网络加速与内核管理子系统**（输入 `x-ui bbr` 随时唤起独立管理菜单），提供兼顾**极致安全**与**极速性能**的双层加速架构：

- **双层加速架构设计**：
  1. **通用免换内核调优层（支持全系统与容器环境）**：
     - **全环境兼容**：完美支持 CentOS、AlmaLinux、Rocky、Ubuntu、Debian、Alpine、Arch 等全系发行版，以及 **LXC / OpenVZ / Docker 容器环境**（无需宿主机换内核权限）。
     - **系统原生 BBR 一键启用/还原**：内核 >= 4.9 即可秒级开启，一键安全回退至系统默认 CUBIC。
     - **多队列算法无缝热切 (Qdisc)**：自由切换 `FQ`（标准推荐）、`FQ_CODEL`（抗缓冲膨胀/防跳 Ping）、`CAKE`（先进队列综合管理）与 `FQ_PIE`。
     - **亚太/跨国线路专属 TCP 优化**：针对跨国节点丢包和长肥管道（Long Fat Network），优化发送/接收缓冲窗口并关闭空闲慢启动，大幅降低断流与卡顿。
     - **智能带宽与 RTT 缓冲计算**：根据节点真实带宽与跨国 RTT 延迟，结合系统内存保护上限，自动化精准配置最优 TCP 缓冲区。
     - **极限测速（疯批）模式**：拉大缓冲区至 1GB、网卡队列长度拉升至 100,000，专用于自有节点极限吞吐压力测试。
  2. **BBR v3 主线内核升级层（Debian/Ubuntu KVM 专属）**：
     - **真正的 Google BBR v3**：支持一键获取并安装最新 Linux 主线内核（打入 Google BBR v3 补丁），提供“标准版 (Standard)”与“激进吞吐版 (Max)”。
     - **多架构支持**：原生适配 `x86_64` (AMD64) 与 `aarch64` (ARM64)。
     - **容器环境安全拦截**：自动识别虚拟化类型，若在 LXC/容器环境中，自动阻止换内核并友好引导使用免换内核调优，规避系统损坏。
     - **版本管理与安全卸载**：支持交互式安装指定历史版本内核，支持一键卸载清理旧版内核并自动重构 GRUB 引导配置。
  3. **Linux 内核安全加固**：
     - 内置 Dirty Frag（CVE 风险）等内核隐患漏洞一键加固策略，在 modprobe 层面拦截并禁用存在隐患的内核模块。

---

## 📋 终端管理菜单总览

在终端输入 `x-ui`，即可呈现全功能结构化管理界面：

```
╔────────────────────────────────────────────────╗
│   3X-UI 面板管理脚本 (已优化版)                 │
│   0. 退出脚本                                  │
│────────────────────────────────────────────────│
│   1. 安装面板                                  │
│   2. 更新面板                                  │
│   3. 更新脚本菜单                              │
│   4. 切换历史版本                              │
│   5. 卸载面板                                  │
│────────────────────────────────────────────────│
│   6. 重置用户名和密码                          │
│   7. 重置网页根路径 (webBasePath)              │
│   8. 重置面板所有设置                          │
│   9. 修改面板监听端口                          │
│  10. 查看当前面板配置                          │
│────────────────────────────────────────────────│
│  11. 启动面板                                  │
│  12. 停止面板                                  │
│  13. 重启面板                                  │
│  14. 重启 Xray 内核                             │
│  15. 查看面板当前状态                          │
│  16. 日志及调试管理                            │
│────────────────────────────────────────────────│
│  17. 启用开机自启                              │
│  18. 禁用开机自启                              │
│────────────────────────────────────────────────│
│  19. SSL 证书管理 (DNS/HTTP 独立申请)          │
│  20. Cloudflare SSL 证书 (DNS API 申请)        │
│  21. 面板 IP 限制管理                          │
│  22. 系统防火墙端口管理                        │
│  23. SSH 端口转发管理                          │
│────────────────────────────────────────────────│
│  24. BBR 网络加速与内核管理                    │
│  25. 手动更新 Geo 数据文件                     │
│  26. 进行 Ookla 速度测试                       │
│────────────────────────────────────────────────│
│  27. PostgreSQL 数据库管理                     │
╚────────────────────────────────────────────────╝
```

---

## 🛠️ 命令行子命令速查

无需进入交互式菜单，直接在命令行中添加子命令即可快速操控：

| 快捷命令 | 功能说明 |
| :--- | :--- |
| `x-ui` | 显示全中文交互管理主菜单 |
| `x-ui bbr` | 呼出 BBR 网络加速与内核管理子菜单 |
| `x-ui start` | 启动 3x-ui 面板服务 |
| `x-ui stop` | 停止 3x-ui 面板服务 |
| `x-ui restart` | 重启 3x-ui 面板服务 |
| `x-ui restart-xray` | 单独重启 Xray 核心 |
| `x-ui status` | 检查面板及 Xray 当前运行状态 |
| `x-ui settings` | 查看当前面板监听端口、登录账户及基础路径 |
| `x-ui enable` | 开启 3x-ui 开机自启 |
| `x-ui disable` | 关闭 3x-ui 开机自启 |
| `x-ui log` | 查看面板运行日志 |
| `x-ui banlog` | 查看 Fail2ban 防爆破封禁日志 |
| `x-ui update` | 执行面板更新流程（保留已有数据） |
| `x-ui legacy` | 交互式切换历史面板及 Xray 版本 |
| `x-ui update-all-geofiles` | 一键更新包括 `geosite_myai.dat` 与 `geosite_ping.dat` 在内的全部规则文件 |
| `x-ui uninstall` | 卸载面板及相关服务 |

---

## 💡 常见问题与实战指南 (FAQ)

### Q1: 如何在 3X-UI 面板中使用 `geosite_myai.dat` 进行 AI 分流？
1. 登录 3X-UI 网页后台，点击左侧菜单的 **【面板设置】 ➔ 【路由设置】**。
2. 在出站规则（Outbounds）中添加您的家宽出口或特定落地节点（Outbound Tag 例如命名为 `ai_out`）。
3. 在路由规则中添加一条新规则：
   - **域名匹配 (geosite)**：输入 `ext:geosite_myai.dat:ai`（或仅分流指定项如 `ext:geosite_myai.dat:antigravity`）
   - **网络协议 (Network)**：**务必留空或填写 `tcp,udp`**（支持 ChatGPT 实时语音 WebRTC 通话，切勿仅勾选 `tcp`）
   - **出站标签 (Outbound)**：选择对应的 `ai_out`
4. 保存配置并点击右上角【重启面板】即可实现 ChatGPT/Claude/Antigravity 等请求自动走专用通道，DeepSeek/Kimi 等国内流量直连，大文件下载不走家宽。

### Q2: 为什么终端菜单一更新容易变成英文原版？
由于上游预编译的归档包中自带官方英文脚本，若曾使用官方菜单选项或通过原版后台触发更新，会重新拉取原版文件。
- **解决方法**：只需在终端执行本项目专属的[一键修复命令](#3-全中文管理菜单一键修复-restore-menu)，即可永久固定为全中文。本项目更新脚本已加入防覆盖防护，后续使用 `x-ui update` 均可保持中文。

### Q3: 为什么不推荐将 Xray-core 升级到 `v26.7.x` 或更高版本？
部分高版本在特定内核协议参数处理以及 Reality 配置回退上有改动，极易导致下游各类 Clash 内核（Mihomo / Clash Verge）报错或 Sing-box 握手失败。推荐保持使用锁定默认的 `v26.6.27`，稳定性最高。

### Q4: 申请 SSL 证书时 80 端口被占用怎么办？
本项目的证书申请工具已内置端口冲突解决机制：
- 若运行有 Nginx/Apache/Caddy/OpenResty 等，脚本会自动安全暂停它们并在验证完成后自动恢复。
- 若有其他未知程序占用了 80 端口，脚本会显示占用进程的 PID 并询问是否强制释放，输入 `y` 即可自动清除阻碍。

### Q5: 分流规则需要定时更新吗？如何进行单独维护与拉取？
**核心结论：不需要频繁定时更新。平时无需理会，按需刷新即可。**
- **无需频繁更新的原因**：
  1. 规则库绝大部分采用“根域名匹配（RootDomain）”（如 `openai.com`、`claude.ai`、`antigravity.google`）。各大平台内部即便新增了几十个多级子域名，也会被 100% 自动匹配，完全不需要更新规则。
  2. 头部 AI 巨头的核心主域名极其稳定，数年内不会变更。
  3. Xray 仅在启动初始化时加载规则库，频繁自动更新并重启会导致当时正在运行的连接瞬断。
- **单独拉取各 .dat 规则库命令**：
  - **单独拉取 AI 专属规则库 (`geosite_myai.dat`)**：
    ```bash
    curl -fLRo /usr/local/x-ui/bin/geosite_myai.dat https://raw.githubusercontent.com/lgdglgc/3x-ui/main/geosite_myai.dat && systemctl restart x-ui
    ```
  - **单独拉取 IP 质量与 Ping 诊断规则库 (`geosite_ping.dat`)**：
    ```bash
    curl -fLRo /usr/local/x-ui/bin/geosite_ping.dat https://raw.githubusercontent.com/lgdglgc/3x-ui/main/geosite_ping.dat && systemctl restart x-ui
    ```
  - **终端一键全部更新**：直接在服务器输入 `x-ui update-all-geofiles`。
- **自动跟随面板更新**：本项目的 `update.sh` 在更新面板时，已自动内置拉取最新 `geosite_myai.dat` 与 `geosite_ping.dat` 的逻辑，因此每次更新面板都会自动保持最新。

### Q6: 访问 Google Gemini 提示“检测到异常流量 (IP 地址：A ≠ B)”是什么原因？如何彻底解决？
#### 1. 现象本质分析
用户常见报错如下：
```text
我们的系统检测到您的计算机网络中存在异常流量。请稍后重新发送请求。
IP 地址：103.11.76.42 ≠ 104.28.227.187 时间：2026-09-20T10:13:59Z 网址：https://gemini.google.com/
```
- **`103.11.76.42`**：服务器购买的原生机房 IP（走 `direct` 直连出站）。
- **`104.28.227.187`**：Cloudflare WARP（或住宅落地 IP）出站。
- **根本原因**：Google 具有极为严格的 **SSO 会话跨 IP 一致性校验**。当访问 Gemini 网页端时，浏览器同时发起页面流式连接（`gemini.google.com`）、账号鉴权校验（`accounts.google.com`、`apis.google.com`）、静态安全脚本（`gstatic.com`）以及 HTTP/3 (QUIC / UDP 443) 请求。若分流规则不完整或入站未嗅探，会导致页面主体走了 WARP，而底层鉴权或 UDP 协议漏网回了 VPS 原生 IP，Google 安全风控判定账号存在**会话劫持（Session Hijacking）或双 IP 异常并发**，立刻直接阻断。

#### 2. 彻底解决实战指南

##### 第一步：配置 3X-UI 黄金双层路由（兼顾防 IP 分裂与 YouTube 免跑流量）
很多用户担心：“如果把 Google 全丢给 WARP 或家宽，看 YouTube 岂不是跑爆流量或被限速？”
**核心解法**：利用 Xray 路由规则**自上而下匹配、首个命中即止（First-Match）**的底层特性：

1. 打开 3X-UI 后台 ➔ 【面板设置】 ➔ 【路由设置】。
2. **规则 1（必须置顶，优先级最高）**：
   - 域名规则：`geosite:youtube`
   - 出站 Tag：选择 `direct`（VPS 原生直连，看 4K/8K 丝滑流畅，完全不耗 WARP 或家宽流量）。
3. **规则 2（紧随其后）**：
   - 域名规则：`ext:geosite_myai.dat:ai`（或追加 `geosite:google`）
   - 网络协议：留空或填写 `tcp,udp`（**切勿仅勾选 tcp**）
   - 出站 Tag：选择 `warp` / `ai_out`（Gemini 页面与 Google 核心鉴权完全统一出站，IP 绝对一致）。
4. **规则 3**：
   - 域名规则：`geosite:cn`、IP 规则：`geoip:cn`、出站 Tag：`direct`。

##### 第二步：入站必须开启【嗅探 (Sniffing)】
若客户端（Clash/v2rayN/Shadowrocket）在本地将域名解析成了目标 IP，服务端入站若未开启嗅探，Xray 只能收到纯 IP，导致 `domain` 规则全部失效而掉入默认直连。
1. 在 3X-UI【入站列表】中点击对应节点的【编辑】。
2. 切换到【嗅探 (Sniffing)】选项卡：
   - **开启嗅探**：勾选 `开启`
   - **重写目标 (destOverride)**：勾选 `http`, `tls`, `quic`, `fakedns`（**务必勾选 quic**，防止 Chrome HTTP/3 走漏）
   - **仅路由 (routeOnly)**：建议开启。
3. 保存并重启。

##### 第三步：清理浏览器旧会话 Cookie
由于被拦截时 Google 已在浏览器 Cookie 与 LocalStorage 中植入了阻断标记：
1. 彻底关闭所有 Gemini 相关标签页。
2. 打开浏览器的**无痕模式（Incognito / 隐身窗口）**，重新访问 `https://gemini.google.com/`，即可秒开顺畅使用。

### Q7: 如何选择与配置 BBR 加速？我的 VPS 应该用免换内核还是升级 BBR v3？
建议根据您的 VPS 虚拟化类型与实际需求做出最优选择：
- **场景 1：LXC / OpenVZ / 容器化 VPS，或系统为 CentOS / Alpine / Rocky**：
  - **推荐选择**：直接选择菜单选项 `1. 一键开启系统原生 BBR 加速`，随后执行选项 `3. 应用亚太/跨国线路 TCP 智能调优`。
  - **核心优势**：无需更换内核，安全性 100%，不会触碰宿主机底层，几秒钟即可享受 BBR 与跨国 TCP 窗口优化带来的速度飞跃。
- **场景 2：KVM 独立架构或物理机，系统为 Ubuntu 24.04+ 或 Debian 12+**：
  - **推荐选择**：先执行选项 `7. 安装 / 更新 BBR v3 最新内核`（选择标准版），重启系统后执行选项 `3. 应用亚太/跨国线路 TCP 智能调优`。
  - **核心优势**：享受 Google BBR v3 最前沿的主线内核算法，在高丢包和抗抖动场景下性能优势显著。
- **场景 3：测速跑分或极客玩家**：
  - 可尝试选项 `5. 启用极限测速挑战模式`，压榨上行带宽极致性能。

### Q8: 如何在 3X-UI 面板中使用 `geosite_ping.dat` 进行节点纯净度体检？
1. 登录 3X-UI 网页后台，点击 **【面板设置】 ➔ 【路由设置】**。
2. 在路由规则列表中添加一条新规则：
   - **域名匹配 (geosite)**：输入 `ext:geosite_ping.dat:ping`（或仅测风控欺诈分填 `ext:geosite_ping.dat:fraud`）
   - **出站标签 (Outbound)**：选择您希望体检的目标节点出站（例如落地节点或美国家宽节点）
3. 保存并点击【重启面板】生效。
4. 此后在浏览器中打开 `ping0.cc`、`scamalytics.com`、`whoer.net` 等网站体检时，流量均精准通过该节点路由，且完全不会触发任何消耗大量带宽的测速服务。

---

## 📄 开源许可证

本项目基于 [3x-ui](https://github.com/MHSanaei/3x-ui) 二次优化加固，遵循 **GPL-3.0 License** 开源协议。
