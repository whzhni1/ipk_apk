# OpenWrt AutoDeploy 🚀

[![GitHub release](https://img.shields.io/github/v/release/yourname/OpenWrt-AutoDeploy)](https://github.com/yourname/OpenWrt-AutoDeploy)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> 智能的 OpenWrt 插件自动部署与更新解决方案

## 为什么需要这个项目？

### 🎯 解决固件构建的痛点

传统固件构建方式存在两个主要问题：

1. **空间浪费**：构建时集成插件会占用 ROM 和 overlay 的双倍存储空间
2. **更新困难**：固件内置插件更新需要重新刷写整个系统

### 🌐 多平台分发优势

通过 GitHub Actions 自动从各大仓库拉取插件并发布到多个平台：
- **GitLab**、**Gitee**、**GitCode** - 国内用户无需梯子即可高速下载
- **版本控制**：自定义标签命名，版本比官方源更新更快
- **格式统一**：标准化包格式，确保兼容性

## 项目特色 ✨

- 🚀 **零配置部署**：首次启动自动安装预设插件
- 🔄 **智能更新**：支持定时自动检查更新
- 📦 **多源支持**：官方源 + 第三方源双重保障
- 🔧 **灵活配置**：支持自定义插件列表和排除列表
- 📱 **推送通知**：集成多种推送服务，实时掌握更新状态
- 🌍 **全球加速**：多平台分发，确保下载速度和稳定性

## 快速开始 🚀

## 配置说明 ⚙️
|参数名 |	属性 |  用法     |	作用  |  说明
|------|--------|-----------|----------|--------|
|INSTALL_PRIORITY|可选	|INSTALL_PRIORITY="1"	|设置安装策略	|1=第三方源优先，其他值或空值=官方源优先
|PACKAGES| 可选	|PACKAGES="luci-app-ttyd tailscale"|	自定义安装插件列表|	多个插件用空格分隔，不设置则使用默认列表
|CRON_TIME| 可选	|CRON_TIME="0 4 * * *"	|设置自动更新定时任务|	标准 crontab 格式，不设置则禁用自动更新
|PUSH_TOKEN| 可选	|PUSH_TOKEN="你的TOKEN"|	安装或更新时推送通知	|支持 ServerChan Turbo、PushPlus、ServerChan 令牌
|AUTHORS| 可选	|AUTHORS="自定义作者"	|设置插件作者项目	|从指定作者的项目仓库下载插件
|EXCLUDE_PACKAGES| 可选	|EXCLUDE_PACKAGES="abc def"|	设置排除更新列表|多个包名用空格分隔，不参与自动更新
|SCRIPT_URLS	| 必需 |URL	|脚本下载源	|支持 GitHub、GitLab、Gitee、GitCode 等，支持带访问令牌， https://xxx≈访问令牌
 
  ---
### 1. 基础使用
在 OpenWrt 构建页面的「自定义固件」-「首次启动脚本」中添加：

```bash
#!/bin/sh
# 自动插件部署脚本
fetch_url="https://raw.githubusercontent.com/yourname/OpenWrt-AutoDeploy/main/install.sh"
curl -fsSL --max-time 30 "$fetch_url" | sh
 ```

### 2. 高级配置
创建引导配置文件 /etc/init.d/auto-setup-fetch：
```bash
#!/bin/sh
at > /etc/init.d/auto-setup-fetch <<'EOF'
#!/bin/sh /etc/rc.common
START=99

SETUP="/etc/init.d/auto-setup"
LOG="/tmp/auto-setup-fetch.log"

# 可选配置
# CRON_TIME="0 4 * * *"           # 定时任务
# INSTALL_PRIORITY="1"            # 安装策略 (1第三方优先)
# AUTHORS="自定义作者"           # 从设置的作者项目里下载包多个用空格分割
# PACKAGES="luci-app-xxx tailscale"  # 自定义包列表
# PUSH_TOKEN="你的令牌"  # 可选：支持ServerChan Turbo PushPlus ServerChan令牌
# EXCLUDE_PACKAGES="自定义排除列表"  # 设置排除更新的包，多个用空格分割
# URLs添加访问令牌实例：https://xxx≈访问令牌，添加多个URLs地址每行一个

SCRIPT_URLS="https://raw.githubusercontent.com/whzhni1/ipk_apk/refs/heads/main/auto-setup
https://gitlab.com/whzhni/ipk_apk/-/raw/main/auto-setup
https://raw.gitcode.com/whzhni/ipk_apk/raw/main/auto-setup
https://gitee.com/whzhni/ipk_apk/raw/main/auto-setup"

log() { echo "[$(date '+%F %T')] $1"; }

start() {
    (
      exec >>$LOG 2>&1
      log "启动下载任务"
      sleep 120

      type curl >/dev/null 2>&1 || {
        log "安装 curl..."
        command -v opkg >/dev/null && { opkg update && opkg install curl; } || { apk update && apk add curl; }
      }

      while true; do
          for i in 1 2 3; do
              log "第 $i 次尝试..."
              for url in $SCRIPT_URLS; do
                  curl -fsSL --max-time 5 "$url" -o $SETUP && {
                      log "✓ 下载成功: $(echo "$url" | cut -d'/' -f1-3)"
                      chmod +x $SETUP
                      $SETUP enable
                      $SETUP start
                      log "✓ auto-setup 已启动"
                      exit 0
                  }
              done
              sleep 10
          done
          log "✗ 失败，30分钟后重试"
          sleep 1800
      done
    ) &
}
EOF

FETCH="/etc/init.d/auto-setup-fetch"
chmod +x $FETCH
$FETCH enable
$FETCH start
echo "[$(date '+%F %T')] ✓ 已启动"
 ```
插件仓库 🗃️
项目自动维护以下插件的多平台分发：

插件名称	描述	更新频率
luci-theme-aurora	极光主题	每日
luci-app-filemanager	文件管理	每日
luci-app-openclash	Clash 客户端	每日
luci-app-passwall2	代理工具	每日
tailscale	组网工具	每日
lucky	内网穿透	每日

致谢 🙏
感谢所有插件的开发者

感谢 OpenWrt 社区

感谢各大代码托管平台提供的服务
