# OpenWrt AutoDeploy 🚀

[![GitHub release](https://img.shields.io/github/v/release/yourname/OpenWrt-AutoDeploy)](https://github.com/yourname/OpenWrt-AutoDeploy)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> 智能的 OpenWrt 插件自动部署与更新解决方案

## 为什么需要这个项目？

### 🎯 解决固件构建的痛点

传统固件构建方式存在四个主要问题：

1. **空间浪费**：构建时集成插件升级插件会占用 ROM 和 overlay 的双倍存储空间
2. **更新困难**：固件内置插件更新不想占用双倍空间需要重新刷写整个系统
3. **浪费精力**：如固件不内置插件每次更新固件都要手动安装
4. **费时费心**：插件有没有更新都要手动操作才知道

## 项目特色 ✨

- 🚀 **零配置部署**：首次启动自动安装预设插件
- 🔄 **智能更新**：支持定时自动检查更新插件
- 📦 **多源支持**：官方源 + 第三方源双重保障
- 🔧 **灵活配置**：支持自定义插件列表和排除列表
- 📱 **推送通知**：集成多种推送服务，实时掌握更新状态
- 🌍 **全球加速**：多平台分发，确保下载速度和稳定性

### 🌐 多平台分发优势

通过 GitHub Actions 自动从各大仓库拉取插件并发布到多个平台：
- **GitLab**、**Gitee**、**GitCode** - 国内用户无需梯子即可高速下载
- **版本控制**：自定义标签命名，版本比官方源更新更快
- **格式统一**：标准化包格式，确保兼容性

## 快速开始 🚀

## 配置说明 ⚙️
|参数名 |	属性 |  用法     |	作用  |  说明
|------|--------|-----------|----------|--------|
|INSTALL_PRIORITY|可选	|INSTALL_PRIORITY="1"	|设置安装策略	|1=第三方源优先，其他值或空值=官方源优先|
|PACKAGES| 可选	|PACKAGES="luci-app-ttyd tailscale"|	自定义安装插件列表|	多个插件用空格分隔，不设置则使用默认列表|
|CRON_TIME| 可选	|CRON_TIME="0 4 * * *"	|设置自动更新定时任务|	标准 crontab 格式，不设置则禁用自动更新|
|PUSH_TOKEN| 可选	|PUSH_TOKEN="你的TOKEN"|	安装或更新时推送通知	|支持 ServerChan Turbo、PushPlus、ServerChan 令牌|
|AUTHORS| 可选	|AUTHORS="自定义作者"	|设置插件作者项目	|从指定作者的项目仓库下载插件|
|EXCLUDE_PACKAGES| 可选	|EXCLUDE_PACKAGES="abc def"|	设置排除更新列表|多个包名用空格分隔，不参与自动更新|
|SCRIPT_URLS	| 必需 |SCRIPT_URLS="URL1"|脚本下载源	|支持 GitHub、GitLab、Gitee、GitCode 等，支持带访问令牌， https://xxx≈访问令牌|
 
  ---
### 使用实例.:
在 OpenWrt 构建页面的「自定义固件」→「首次启动脚本」中添加[![auto-setup-fetch](https://raw.githubusercontent.com/whzhni1/OpenWrt-AutoDeploy/refs/heads/main/auto-setup-fetch)中的代码：

插件仓库 🗃️
项目自动维护以下插件的多平台分发：

|插件 名称	| 描述	| 更新频率|
|---------------|------------|--------|
|luci-theme-aurora	|极光主题|	每日|
|luci-app-openclash|	Clash 客户端	|每日|
|luci-app-passwall2	|代理工具	|每日|
|tailscale	|组网工具	|每日|
|lucky	|内网穿透|	每日|
|openlist2	|网盘挂载|	每日|
---

致谢 🙏
感谢所有插件的开发者

感谢 OpenWrt 社区

感谢各大代码托管平台提供的服务
