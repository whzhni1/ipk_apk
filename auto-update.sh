#!/bin/sh

SCRIPT_VERSION="2.0.0"
LOG_FILE="/tmp/auto-update.log"
CONFIG_BACKUP_DIR="/tmp/config_Backup"
DEVICE_MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo '未知设备')"
PUSH_TITLE="$DEVICE_MODEL 插件更新通知"
USER_AGENT="Mozilla/5.0 (compatible; OpenWrt-AutoUpdate/2.0)"
EXCLUDE_PACKAGES="kernel kmod- base-files busybox lib opkg uclient-fetch ca-bundle ca-certificates luci-app-lucky"
EMPTY_VARS="SYS_ARCH ARCH_FALLBACK PKG_EXT PKG_INSTALL PKG_UPDATE AUTO_UPDATE CRON_TIME INSTALL_PRIORITY GITEE_TOKEN GITCODE_TOKEN THIRD_PARTY_INSTALLED API_SOURCES"

for var in $EMPTY_VARS; do eval "$var=''"; done
CONFIG_BACKED_UP=0

# 日志函数
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
    logger -t "auto-update" "$1" 2>/dev/null || true
}

# 加载配置文件
load_config() {
    local conf="/etc/auto-setup.conf"
    if [ -f "$conf" ]; then
        . "$conf"
        log "✓ 配置已加载: $conf"
        
        if [ -z "$SYS_ARCH" ] || [ -z "$PKG_INSTALL" ] || [ -z "$API_SOURCES" ]; then
            log "✗ 缺少关键配置: SYS_ARCH=$SYS_ARCH PKG_INSTALL=$PKG_INSTALL"
            return 1
        fi
        return 0
    else
        log "✗ 配置文件不存在: $conf"
        return 1
    fi
}

# 通用工具函数
format_size() {
    local bytes="$1"
    case 1 in
        $(($bytes > 1048576))) echo "$((bytes / 1048576)) MB" ;;
        $(($bytes > 1024))) echo "$((bytes / 1024)) KB" ;;
        *) echo "$bytes 字节" ;;
    esac
}

# 验证下载文件
validate_downloaded_file() {
    local filepath="$1"
    local min_size="${2:-1024}"
    
    [ ! -f "$filepath" ] || [ ! -s "$filepath" ] && { log "  ✗ 文件不存在或为空: $filepath"; return 1; }
    
    local size=$(wc -c < "$filepath" 2>/dev/null | tr -d ' ' || echo "0")
    
    [ "$size" -lt "$min_size" ] && head -1 "$filepath" 2>/dev/null | grep -qi "<!DOCTYPE\|<html" && {
        log "  ✗ 下载的是HTML页面: $filepath"
        return 1
    }
    
    log "  ✓ 文件有效: $(format_size $size)"
    return 0
}

# 获取平台token
get_token_for_platform() {
    case "$1" in
        gitee) echo "$GITEE_TOKEN" ;;
        gitcode) echo "$GITCODE_TOKEN" ;;
        *) echo "" ;;
    esac
}

# 获取所有tags
api_get_tags() {
    local platform="$1" owner="$2" repo="$3"
    local token=$(get_token_for_platform "$platform")
    local api_url=""
    
    case "$platform" in
        gitee)
            api_url="https://gitee.com/api/v5/repos/${owner}/${repo}/tags"
            [ -n "$token" ] && api_url="${api_url}?access_token=${token}"
            curl -s "$api_url"
            ;;
        gitcode)
            api_url="https://api.gitcode.com/api/v5/repos/${owner}/${repo}/tags"
            [ -n "$token" ] && curl -s -H "Authorization: Bearer $token" "$api_url" || curl -s "$api_url"
            ;;
        *) return 1 ;;
    esac
}

# 获取指定tag的Release
api_get_release_by_tag() {
    local platform="$1" owner="$2" repo="$3" tag="$4"
    local token=$(get_token_for_platform "$platform")
    local api_url=""
    
    case "$platform" in
        gitee)
            api_url="https://gitee.com/api/v5/repos/${owner}/${repo}/releases/tags/${tag}"
            [ -n "$token" ] && api_url="${api_url}?access_token=${token}"
            curl -s "$api_url"
            ;;
        gitcode)
            api_url="https://api.gitcode.com/api/v5/repos/${owner}/${repo}/releases/tags/${tag}"
            [ -n "$token" ] && curl -s -H "Authorization: Bearer $token" "$api_url" || curl -s "$api_url"
            ;;
        *) return 1 ;;
    esac
}

# 标准化版本号
normalize_version() {
    echo "$1" | sed 's/^[vV]//' | sed 's/[-_].*//'
}

# 版本比较
version_greater() {
    local v1=$(normalize_version "$1")
    local v2=$(normalize_version "$2")
    test "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -1)" = "$v1"
}

# 从assets匹配文件
match_files_from_assets() {
    local assets_json="$1" pkg_name="$2"
    local matched="" arch_file="" luci_file="" lang_file=""
    
    for arch in $ARCH_FALLBACK; do
        arch_file=$(echo "$assets_json" | grep -o '{"[^}]*"name":"[^"]*'"$arch"'[^"]*'"$PKG_EXT"'"[^}]*}' | head -1)
        [ -n "$arch_file" ] && { matched="$matched|$arch_file"; break; }
    done
    
    luci_file=$(echo "$assets_json" | grep -o '{"[^}]*"name":"luci-[^"]*'"$PKG_EXT"'"[^}]*}' | head -1)
    [ -n "$luci_file" ] && matched="$matched|$luci_file"
    
    lang_file=$(echo "$assets_json" | grep -o '{"[^}]*"name":"[^"]*zh-cn[^"]*'"$PKG_EXT"'"[^}]*}' | head -1)
    [ -n "$lang_file" ] && matched="$matched|$lang_file"
    
    echo "$matched"
}

# 下载并安装文件
download_and_install_files() {
    local files="$1" pkg_name="$2"
    local old_IFS="$IFS"
    IFS='|'
    
    for file_json in $files; do
        [ -z "$file_json" ] && continue
        
        local filename=$(echo "$file_json" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
        local download_url=$(echo "$file_json" | grep -o '"browser_download_url":"[^"]*"' | cut -d'"' -f4)
        
        [ -z "$download_url" ] && { log "  ✗ 未找到下载链接: $filename"; IFS="$old_IFS"; return 1; }
        
        log "  下载: $filename"
        
        if curl -fsSL -o "/tmp/$filename" "$download_url" 2>/dev/null && validate_downloaded_file "/tmp/$filename" 10240; then
            log "  安装: $filename"
            if $PKG_INSTALL "/tmp/$filename" >>"$LOG_FILE" 2>&1; then
                log "  ✓ $filename 安装成功"
            else
                log "  ✗ $filename 安装失败"
                rm -f "/tmp/$filename"
                IFS="$old_IFS"
                return 1
            fi
            rm -f "/tmp/$filename"
        else
            log "  ✗ $filename 下载失败 $download_url"
            rm -f "/tmp/$filename"
            IFS="$old_IFS"
            return 1
        fi
    done
    
    IFS="$old_IFS"
    return 0
}

# 统一的包处理函数
process_package() {
    local pkg="$1" check_version="${2:-0}" current_ver="$3"
    
    log "处理包: $pkg"
    
    for source_config in $API_SOURCES; do
        local platform=$(echo "$source_config" | cut -d'|' -f1)
        local owner=$(echo "$source_config" | cut -d'|' -f2 | cut -d'/' -f1)
        
        log "  平台: $platform ($owner/$pkg)"
        
        local tags_json=$(api_get_tags "$platform" "$owner" "$pkg")
        
        echo "$tags_json" | grep -q '"name"' || {
            if echo "$tags_json" | grep -q '"message"'; then
                local error=$(echo "$tags_json" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 | head -1)
                echo "$error" | grep -q "404\|Not Found\|does not exist" && log "  ✗ 仓库不存在: $owner/$pkg"
            else
                log "  ✗ 获取tags失败: 无响应"
            fi
            continue
        }
        
        local latest_tag=$(echo "$tags_json" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
        
        [ -z "$latest_tag" ] && { log "  ✗ 未找到版本"; continue; }
        
        log "  最新版本: $latest_tag"
        
        [ "$check_version" = "1" ] && {
            version_greater "$latest_tag" "$current_ver" || { log "  ○ 当前版本已是最新 ($current_ver)"; return 2; }
            log "  发现新版本: $current_ver → $latest_tag"
        }
        
        local release_json=$(api_get_release_by_tag "$platform" "$owner" "$pkg" "$latest_tag")
        
        echo "$release_json" | grep -q '"assets"' || {
            if echo "$release_json" | grep -q '"message"'; then
                local error=$(echo "$release_json" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
                log "  ✗ Release错误: $error"
            else
                log "  ✗ 未找到Release"
            fi
            continue
        }
        
        local assets=$(echo "$release_json" | sed -n '/"assets":\[/,/\]/p')
        
        echo "$assets" | grep -q '\[\]' && { log "  ✗ assets为空"; continue; }
        
        local files=$(match_files_from_assets "$assets" "$pkg")
        
        [ -z "$files" ] && { log "  ✗ 未找到匹配的文件"; continue; }
        
        download_and_install_files "$files" "$pkg" && { log "  ✓ $pkg 安装成功"; return 0; }
        
        log "  ✗ 安装失败"
    done
    
    log "✗ $pkg 所有源均失败"
    return 1
}

# 保存到配置文件
save_third_party_to_config() {
    local new_packages="$1"
    local conf="/etc/auto-setup.conf"
    
    [ ! -f "$conf" ] && { log "✗ 配置文件不存在: $conf"; return 1; }
    
    local existing=$(grep "^THIRD_PARTY_INSTALLED=" "$conf" 2>/dev/null | cut -d'"' -f2)
    local combined=$(echo "$existing $new_packages" | xargs | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)
    
    if grep -q "^THIRD_PARTY_INSTALLED=" "$conf"; then
        sed -i "s|^THIRD_PARTY_INSTALLED=.*|THIRD_PARTY_INSTALLED=\"$combined\"|" "$conf"
    else
        echo "" >> "$conf"
        echo "# 第三方源安装的包" >> "$conf"
        echo "THIRD_PARTY_INSTALLED=\"$combined\"" >> "$conf"
    fi
    
    log "✓ 配置已更新: $combined"
}

# install模式
run_install() {
    local packages="$*"
    
    log "第三方源安装模式"
    log "包列表: $packages"
    
    local installed="" failed=""
    
    for pkg in $packages; do
        log ""
        process_package "$pkg" 0 && installed="$installed $pkg" || failed="$failed $pkg"
    done
    
    [ -n "$installed" ] && save_third_party_to_config "$installed"
    
    log ""
    log "安装汇总: 成功 $(echo $installed | wc -w), 失败 $(echo $failed | wc -w)"
}

# 获取更新周期
get_update_schedule() {
    local cron_entry
    cron_entry=$(crontab -l 2>/dev/null | grep "auto-update.sh" | grep -v "^#" | head -n1)
    [ -z "$cron_entry" ] && { echo "未设置"; return; }

    local minute hour day weekday
    minute=$(echo "$cron_entry" | awk '{print $1}')
    hour=$(echo "$cron_entry" | awk '{print $2}')
    day=$(echo "$cron_entry" | awk '{print $3}')
    weekday=$(echo "$cron_entry" | awk '{print $5}')

    local week_name=""
    case "$weekday" in
        0|7) week_name="日" ;;
        1)   week_name="一" ;;
        2)   week_name="二" ;;
        3)   week_name="三" ;;
        4)   week_name="四" ;;
        5)   week_name="五" ;;
        6)   week_name="六" ;;
    esac
    case "$weekday" in
        [0-7])
            if [ "$hour" != "*" ]; then
                printf "每周%s %02d点\n" "$week_name" "$hour"
            else
                echo "每周${week_name}"
            fi
            return
            ;;
    esac
    case "$hour" in
        "*/"*)
            echo "每${hour#*/}小时"
            return
            ;;
    esac
    case "$day" in
        "*/"*)
            if [ "$hour" != "*" ]; then
                printf "每%s天 %02d点\n" "${day#*/}" "$hour"
            else
                echo "每${day#*/}天"
            fi
            return
            ;;
    esac
    if [ "$day" = "*" ] && echo "$hour" | grep -q '^[0-9]\+$'; then
        printf "每天%02d点\n" "$hour"
        return
    fi
    case "$minute" in
        "*/"*)
            echo "每${minute#*/}分钟"
            return
            ;;
    esac
    echo "$minute $hour $day * $weekday"
}

# 状态推送
send_status_push() {
    : > "$LOG_FILE"
    log "发送状态推送"
    
    load_config
    
    local schedule=$(get_update_schedule)
    local message="自动更新已打开\n\n**脚本版本**: $SCRIPT_VERSION\n**自动更新时间**: $schedule\n\n---\n设备: $DEVICE_MODEL\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    log "推送内容: 版本 $SCRIPT_VERSION, 计划 $schedule"
    send_push "$PUSH_TITLE" "$message"
    log "状态推送完成"
}

# 包管理函数
is_package_excluded() {
    case "$1" in luci-i18n-*) return 0 ;; esac
    for pattern in $EXCLUDE_PACKAGES; do
        case "$1" in $pattern*) return 0 ;; esac
    done
    return 1
}

is_installed() {
    echo "$PKG_INSTALL" | grep -q "opkg" && opkg list-installed | grep -q "^$1 " || apk info -e "$1" >/dev/null 2>&1
}

get_package_version() {
    case "$1" in
        list-installed)
            echo "$PKG_INSTALL" | grep -q "opkg" && opkg list-installed | grep "^$2 " | awk '{print $3}' || \
                apk info "$2" 2>/dev/null | grep "^$2-" | sed "s/^$2-//" | cut -d'-' -f1
            ;;
        list)
            echo "$PKG_INSTALL" | grep -q "opkg" && opkg list | grep "^$2 " | awk '{print $3}' || \
                apk search "$2" 2>/dev/null | grep "^$2-" | sed "s/^$2-//" | cut -d'-' -f1
            ;;
    esac
}

# 安装语言包
install_language_package() {
    local pkg="$1" lang_pkg=""
    
    case "$pkg" in
        luci-app-*) lang_pkg="luci-i18n-${pkg#luci-app-}-zh-cn" ;;
        luci-theme-*) lang_pkg="luci-i18n-theme-${pkg#luci-theme-}-zh-cn" ;;
        *) return 0 ;;
    esac
    
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        opkg list 2>/dev/null | grep -q "^$lang_pkg " || return 0
    else
        apk search "$lang_pkg" 2>/dev/null | grep -q "^$lang_pkg" || return 0
    fi
    
    local action="安装"
    is_installed "$lang_pkg" && action="升级"
    
    log "    ${action}语言包 $lang_pkg..."
    $PKG_INSTALL "$lang_pkg" >>"$LOG_FILE" 2>&1 && log "    ✓ $lang_pkg ${action}成功" || log "    ⚠ $lang_pkg ${action}失败"
}

# 配置备份
backup_config() {
    [ $CONFIG_BACKED_UP -eq 1 ] && return 0
    
    log "  备份配置到 $CONFIG_BACKUP_DIR"
    rm -rf "$CONFIG_BACKUP_DIR" 2>/dev/null
    mkdir -p "$CONFIG_BACKUP_DIR"
    cp -r /etc/config/* "$CONFIG_BACKUP_DIR/" 2>/dev/null && log "  ✓ 配置备份成功" || log "  ⚠ 配置备份失败"
    
    CONFIG_BACKED_UP=1
}

# 推送函数
send_push() {
    [ ! -f "/etc/config/wechatpush" ] && { log "⚠ wechatpush未安装"; return 1; }
    [ "$(uci get wechatpush.config.enable 2>/dev/null)" != "1" ] && { log "⚠ wechatpush未启用"; return 1; }
    
    local token=$(uci get wechatpush.config.pushplus_token 2>/dev/null)
    local api="pushplus" url="http://www.pushplus.plus/send"
    
    if [ -z "$token" ]; then
        token=$(uci get wechatpush.config.serverchan_3_key 2>/dev/null)
        api="serverchan3" url="https://sctapi.ftqq.com/${token}.send"
    fi
    
    if [ -z "$token" ]; then
        token=$(uci get wechatpush.config.serverchan_key 2>/dev/null)
        api="serverchan" url="https://sc.ftqq.com/${token}.send"
    fi
    
    [ -z "$token" ] && { log "⚠ 未配置推送"; return 1; }
    
    log "发送推送 ($api)"
    
    local response=""
    case "$api" in
        pushplus)
            local content=$(echo "$2" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
            response=$(curl -s -X POST "$url" -H "Content-Type: application/json" \
                -d "{\"token\":\"$token\",\"title\":\"$1\",\"content\":\"$content\",\"template\":\"txt\"}")
            echo "$response" | grep -q '"code":200' && { log "✓ 推送成功"; return 0; }
            ;;
        *)
            response=$(curl -s -X POST "$url" -d "text=$1" -d "desp=$2")
            echo "$response" | grep -q '"errno":0\|"code":0' && { log "✓ 推送成功"; return 0; }
            ;;
    esac
    
    log "✗ 推送失败: $response"
    return 1
}

# 包分类
classify_packages() {
    log "步骤: 分类已安装的包"
    log "更新软件源..."
    
    $PKG_UPDATE >>"$LOG_FILE" 2>&1 || { log "✗ 软件源更新失败"; return 1; }
    log "✓ 软件源更新成功"
    
    OFFICIAL_PACKAGES=""
    NON_OFFICIAL_PACKAGES=""
    EXCLUDED_COUNT=0
    
    local pkgs=""
    echo "$PKG_INSTALL" | grep -q "opkg" && pkgs=$(opkg list-installed | awk '{print $1}' | grep -v "^luci-i18n-") || \
        pkgs=$(apk info 2>/dev/null | grep -v "^luci-i18n-")
    
    local total=$(echo "$pkgs" | wc -l)
    log "检测到 $total 个已安装包（已排除语言包）"
    
    for pkg in $pkgs; do
        if echo " $THIRD_PARTY_INSTALLED " | grep -q " $pkg "; then
            NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
        elif is_package_excluded "$pkg"; then
            EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
        elif echo "$PKG_INSTALL" | grep -q "opkg"; then
            opkg info "$pkg" 2>/dev/null | grep -q "^Description:" && OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg" || \
                NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
        else
            apk info "$pkg" 2>/dev/null | grep -q "^origin:" && OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg" || \
                NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
        fi
    done
    
    log "包分类完成: 官方源 $(echo $OFFICIAL_PACKAGES | wc -w), 第三方源 $(echo $NON_OFFICIAL_PACKAGES | wc -w), 排除 $EXCLUDED_COUNT"
    return 0
}

# 官方源更新
update_official_packages() {
    log "步骤: 更新官方源中的包"
    
    OFFICIAL_UPDATED=0 OFFICIAL_SKIPPED=0 OFFICIAL_FAILED=0
    UPDATED_PACKAGES="" FAILED_PACKAGES=""
    
    for pkg in $OFFICIAL_PACKAGES; do
        local cur=$(get_package_version list-installed "$pkg")
        local new=$(get_package_version list "$pkg")
        
        if [ "$cur" != "$new" ] && [ -n "$new" ]; then
            log "↻ $pkg: $cur → $new"
            
            if echo "$PKG_INSTALL" | grep -q "opkg"; then
                opkg upgrade "$pkg" >>"$LOG_FILE" 2>&1 && {
                    log "  ✓ 升级成功"
                    UPDATED_PACKAGES="${UPDATED_PACKAGES}\n    - $pkg: $cur → $new"
                    OFFICIAL_UPDATED=$((OFFICIAL_UPDATED + 1))
                    install_language_package "$pkg"
                } || {
                    log "  ✗ 升级失败"
                    FAILED_PACKAGES="${FAILED_PACKAGES}\n    - $pkg"
                    OFFICIAL_FAILED=$((OFFICIAL_FAILED + 1))
                }
            else
                apk upgrade "$pkg" >>"$LOG_FILE" 2>&1 && {
                    log "  ✓ 升级成功"
                    UPDATED_PACKAGES="${UPDATED_PACKAGES}\n    - $pkg: $cur → $new"
                    OFFICIAL_UPDATED=$((OFFICIAL_UPDATED + 1))
                } || {
                    log "  ✗ 升级失败"
                    FAILED_PACKAGES="${FAILED_PACKAGES}\n    - $pkg"
                    OFFICIAL_FAILED=$((OFFICIAL_FAILED + 1))
                }
            fi
        else
            log "○ $pkg: $cur (已是最新)"
            OFFICIAL_SKIPPED=$((OFFICIAL_SKIPPED + 1))
        fi
    done
    
    log "官方源检查完成: 升级 $OFFICIAL_UPDATED, 已是最新 $OFFICIAL_SKIPPED, 失败 $OFFICIAL_FAILED"
    return 0
}

# 第三方源更新
update_thirdparty_packages() {
    log "步骤: 检查并更新第三方源的包"
    
    THIRDPARTY_UPDATED=0 THIRDPARTY_SAME=0 THIRDPARTY_NOTFOUND=0 THIRDPARTY_FAILED=0
    
    local check_list=""
    for pkg in $NON_OFFICIAL_PACKAGES; do
        case "$pkg" in
            luci-app-*|luci-theme-*|lucky) check_list="$check_list $pkg" ;;
        esac
    done
    
    local count=$(echo $check_list | wc -w)
    [ $count -eq 0 ] && { log "没有需要检查的第三方插件"; return 0; }
    
    log "需要检查的第三方插件: $count 个"
    
    for pkg in $check_list; do
        local cur=$(get_package_version list-installed "$pkg")
        log "🔍 检查 $pkg (当前版本: $cur)"
        
        local ret=$(process_package "$pkg" 1 "$cur"; echo $?)
        
        case $ret in
            0) THIRDPARTY_UPDATED=$((THIRDPARTY_UPDATED + 1)) ;;
            2) THIRDPARTY_SAME=$((THIRDPARTY_SAME + 1)) ;;
            *) THIRDPARTY_FAILED=$((THIRDPARTY_FAILED + 1)) ;;
        esac
    done
    
    log "第三方源检查完成: 已更新 $THIRDPARTY_UPDATED, 已是最新 $THIRDPARTY_SAME, 失败 $THIRDPARTY_FAILED"
    return 0
}

# 脚本自更新
check_script_update() {
    log "检查脚本更新"
    log "当前脚本版本: $SCRIPT_VERSION"
    
    for source_config in $API_SOURCES; do
        local platform=$(echo "$source_config" | cut -d'|' -f1)
        local repo=$(echo "$source_config" | cut -d'|' -f2)
        local branch=$(echo "$source_config" | cut -d'|' -f3)
        
        log "尝试从 $platform 获取版本信息"
        
        case "$platform" in
            gitee) local url="https://gitee.com/${repo}/raw/${branch}/auto-update.sh" ;;
            gitcode) local url="https://gitcode.com/${repo}/raw/${branch}/auto-update.sh" ;;
            *) continue ;;
        esac
        
        local header=$(curl -fsSL -H "User-Agent: $USER_AGENT" "$url" 2>/dev/null | head -20)
        
        [ -n "$header" ] && {
            local remote_ver=$(echo "$header" | grep -o 'SCRIPT_VERSION="[^"]*"' | head -n1 | cut -d'"' -f2)
            
            [ -n "$remote_ver" ] && {
                log "  ✓ 获取到远程版本: $remote_ver"
                
                [ "$SCRIPT_VERSION" = "$remote_ver" ] && { log "○ 脚本已是最新版本"; return 0; }
                
                log "↻ 发现新版本: $SCRIPT_VERSION → $remote_ver"
                
                local temp="/tmp/auto-update-new.sh"
                local current_script=$(readlink -f "$0")
                
                curl -fsSL -o "$temp" -H "User-Agent: $USER_AGENT" "$url" 2>/dev/null && \
                    validate_downloaded_file "$temp" && \
                    mv "$temp" "$current_script" && \
                    chmod +x "$current_script" && {
                    log "✓ 脚本更新成功！版本: $SCRIPT_VERSION → $remote_ver, 来源: $platform"
                    log "脚本已更新，重新启动新版本"
                    exec "$current_script"
                }
                
                log "✗ 脚本更新失败"
                rm -f "$temp"
            }
        }
    done
    
    return 0
}

# 报告生成
generate_report() {
    local updates=$((OFFICIAL_UPDATED + THIRDPARTY_UPDATED))
    local strategy="官方源优先"
    [ "$INSTALL_PRIORITY" != "1" ] && strategy="第三方源优先"
    
    local non_official_count=$(echo $NON_OFFICIAL_PACKAGES | wc -w)
    
    local report="脚本版本: $SCRIPT_VERSION\n"
    report="${report}==================\n"
    report="${report}时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    report="${report}设备: $DEVICE_MODEL\n"
    report="${report}策略: $strategy\n\n"
    
    report="${report}官方源检查完成:\n"
    report="${report}  ✓ 升级: $OFFICIAL_UPDATED 个\n"
    [ -n "$UPDATED_PACKAGES" ] && report="${report}$UPDATED_PACKAGES\n"
    report="${report}  ○ 已是最新: $OFFICIAL_SKIPPED 个\n"
    report="${report}  ⊗ 不在官方源: $non_official_count 个\n"
    report="${report}  ⊝ 排除: $EXCLUDED_COUNT 个\n"
    report="${report}  ✗ 失败: $OFFICIAL_FAILED 个\n"
    [ -n "$FAILED_PACKAGES" ] && report="${report}$FAILED_PACKAGES\n"
    report="${report}\n"
    
    report="${report}第三方源检查完成:\n"
    report="${report}  ✓ 已更新: $THIRDPARTY_UPDATED 个\n"
    report="${report}  ○ 已是最新: $THIRDPARTY_SAME 个\n"
    report="${report}  ✗ 失败: $THIRDPARTY_FAILED 个\n"
    report="${report}\n"
    
    [ $updates -eq 0 ] && report="${report}[提示] 所有软件包均为最新版本\n\n"
    
    report="${report}==================\n"
    report="${report}详细日志: $LOG_FILE"
    
    echo "$report"
}

# update模式
run_update() {
    rm -f "$LOG_FILE"
    touch "$LOG_FILE"
    
    log "OpenWrt 自动更新脚本 v${SCRIPT_VERSION}"
    log "开始执行 (PID: $$)"
    log "日志文件: $LOG_FILE"
    
    load_config || return 1
    
    echo "$PKG_INSTALL" | grep -q "opkg" && PKG_UPDATE="opkg update" || PKG_UPDATE="apk update"
    
    log "系统架构: $SYS_ARCH"
    log "包管理器: $(echo $PKG_INSTALL | awk '{print $1}')"
    log "包格式: $PKG_EXT"
    log "安装优先级: $([ "$INSTALL_PRIORITY" = "1" ] && echo "官方源优先" || echo "第三方源优先")"
    
    check_script_update
    classify_packages || return 1
    
    case "$INSTALL_PRIORITY" in
        1) 
            log "[策略] 官方源优先，第三方源补充"
            update_official_packages
            update_thirdparty_packages
            ;;
        *)
            log "[策略] 第三方源优先，官方源补充"
            update_thirdparty_packages
            update_official_packages
            ;;
    esac
    
    [ $CONFIG_BACKED_UP -eq 1 ] && [ -d "$CONFIG_BACKUP_DIR" ] && {
        log ""
        log "配置备份信息"
        log "备份目录: $CONFIG_BACKUP_DIR"
    }
    
    log "✓ 更新流程完成"
    
    local report=$(generate_report)
    log "$report"
    
    send_push "$PUSH_TITLE" "$report"
}

# 参数处理
case "$1" in
    ts) send_status_push ;;
    install) shift; load_config && run_install "$@" ;;
    *) run_update ;;
esac
