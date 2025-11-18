#!/bin/sh

SCRIPT_VERSION="2.1.1"
LOG_FILE="/tmp/auto-update.log"
CONFIG_BACKUP_DIR="/tmp/config_Backup"
DEVICE_MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo '未知设备')"
PUSH_TITLE="$DEVICE_MODEL 插件更新通知"
USER_AGENT="Mozilla/5.0 (compatible; OpenWrt-AutoUpdate/2.0)"
EXCLUDE_PACKAGES="kernel kmod- base-files busybox lib opkg uclient-fetch ca-bundle ca-certificates luci-app-lucky luci-app-openlist2 luci-app-tailscale"
EMPTY_VARS="SYS_ARCH ARCH_FALLBACK PKG_EXT PKG_INSTALL PKG_UPDATE AUTO_UPDATE CRON_TIME INSTALL_PRIORITY GITEE_TOKEN GITCODE_TOKEN THIRD_PARTY_INSTALLED API_SOURCES ASSET_FILENAMES ASSETS_JSON_CACHE"

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
        
        [ -z "$SYS_ARCH" ] || [ -z "$PKG_INSTALL" ] || [ -z "$API_SOURCES" ] && {
            log "✗ 缺少关键配置: SYS_ARCH=$SYS_ARCH PKG_INSTALL=$PKG_INSTALL"
            return 1
        }
        return 0
    else
        log "✗ 配置文件不存在: $conf"
        return 1
    fi
}

# 解析源配置
parse_source_config() {
    local source_config="$1"
    platform=$(echo "$source_config" | cut -d'|' -f1)
    repo=$(echo "$source_config" | cut -d'|' -f2)
    branch=$(echo "$source_config" | cut -d'|' -f3)
    owner=$(echo "$source_config" | cut -d'|' -f2 | cut -d'/' -f1)
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

# 转小写函数
to_lower() {
    echo "$1" | tr 'A-Z' 'a-z'
}

# 验证下载文件
validate_downloaded_file() {
    local filepath="$1" min_size="${2:-1024}"
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

# 获取最新Release
api_get_latest_release() {
    local platform="$1" owner="$2" repo="$3"
    local token=$(get_token_for_platform "$platform")
    local api_url=""
    case "$platform" in
        gitee)
            api_url="https://gitee.com/api/v5/repos/${owner}/${repo}/releases"
            if [ -n "$token" ]; then
                curl -s -H "Authorization: token $token" "$api_url"
            else
                curl -s "$api_url"
            fi
            ;;
        gitcode)
            api_url="https://gitcode.com/api/v5/repos/${owner}/${repo}/releases"
            if [ -z "$token" ]; then
                echo "[]"
                return 1
            fi
            curl -s -H "Authorization: Bearer $token" "$api_url"
            ;;
        *) return 1 ;;
    esac
}

# 标准化版本号
normalize_version() {
    echo "$1" | sed 's/^[vV]//' | sed 's/[-_].*//'
}

# 版本比较
normalize_version() {
    echo "$1" | sed 's/^[vV]//' | sed 's/[-_].*//'
}
version_greater() {
    local v1=$(normalize_version "$1")
    local v2=$(normalize_version "$2")
    [ "$v1" = "$v2" ] && return 1
    test "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -1)" = "$v1"
}

# 提取app名称
extract_app_name() {
    local pkg="$1"
    case "$pkg" in
        luci-app-*) echo "${pkg#luci-app-}" ;;
        luci-theme-*) echo "${pkg#luci-theme-}" ;;
        *) echo "$pkg" ;;
    esac
}

# 提取文件名列表
extract_filenames() {
    local json_data="$1"
    ASSETS_JSON_CACHE="$json_data"
    case "$PKG_EXT" in
        .ipk)
            ASSET_FILENAMES=$(echo "$json_data" | grep -o '"name":"[^"]*\.ipk"' | cut -d'"' -f4)
            ;;
        .apk)
            ASSET_FILENAMES=$(echo "$json_data" | grep -o '"name":"[^"]*\.apk"' | cut -d'"' -f4)
            ;;
        *)
            log "  [错误] 不支持的包格式: $PKG_EXT"
            return 1
            ;;
    esac
    [ -z "$ASSET_FILENAMES" ] && {
        log "未找到任何 ${PKG_EXT} 文件"
        return 1
    }
    local count=$(echo "$ASSET_FILENAMES" | wc -l)
    log "成功提取 $count 个文件"
    return 0
}

# 根据文件名查找下载地址
get_download_url() {
    local filename="$1"
    local url=$(echo "$ASSETS_JSON_CACHE" | grep -o "https://[^\"]*${filename}" | head -1)
    url=$(echo "$url" | sed 's|https://api\.gitcode\.com/|https://gitcode.com/|')
    echo "$url"
}

# 获取所有文件名列表
get_all_filenames() {
    echo "$ASSET_FILENAMES"
}

# 下载并安装单个文件
download_and_install_single() {
    local filename="$1"
    local download_url=$(get_download_url "$filename")
    [ -z "$download_url" ] && {
        log "    ✗ 未找到下载地址: $filename"
        return 1
    }
    log "    下载: $filename"
    curl -fsSL -o "/tmp/$filename" "$download_url" 2>/dev/null || {
        log "    ✗ 下载失败"
        return 1
    }
    validate_downloaded_file "/tmp/$filename" 10240 || {
        rm -f "/tmp/$filename"
        return 1
    }
    log "    安装: $filename"
    if $PKG_INSTALL "/tmp/$filename" >>"$LOG_FILE" 2>&1; then
        log "    ✓ 安装成功"
        rm -f "/tmp/$filename"
        return 0
    else
        local error=$(tail -3 "$LOG_FILE" | grep -v '^\[' | xargs)
        log "    ✗ 安装失败: $error"
        log "    文件保留: /tmp/$filename"
        return 1
    fi
}

# 匹配并下载安装
match_and_download() {
    local assets_json="$1" pkg_name="$2" platform="$3"
    local app_name=$(extract_app_name "$pkg_name")
    log "  应用名: $app_name"
    
    extract_filenames "$assets_json" || {
        log "  ✗ 文件名提取失败，平台: $platform"
        return 1
    }
    local all_files=$(get_all_filenames)
    [ -z "$all_files" ] && { 
        log "  ✗ 未找到任何 $PKG_EXT 文件，平台: $platform"
        return 1
    }
    local file_count=$(echo "$all_files" | wc -l)
    log "  找到 $file_count 个 $PKG_EXT 文件"
    if [ "$file_count" -le 5 ]; then
        log "  文件列表:"
        echo "$all_files" | while read fname; do [ -n "$fname" ] && log "    - $fname"; done
    else
        log "  文件列表（前5个）:"
        echo "$all_files" | head -5 | while read fname; do [ -n "$fname" ] && log "    - $fname"; done
        log "    ... 还有 $((file_count - 5)) 个文件"
    fi
    local success_count=0 old_IFS="$IFS"
    local app_name_lower=$(to_lower "$app_name")
    find_package() {
        local pkg_type="$1"
        local arch="$2"
        
        IFS=$'\n'
        for filename in $all_files; do
            IFS="$old_IFS"
            [ -z "$filename" ] && continue
            
            local filename_lower=$(to_lower "$filename")
            local matched=0
            
            case "$pkg_type" in
                arch)
                    case "$filename" in luci-*) continue ;; esac
                    echo "$filename_lower" | grep -q "$arch" && echo "$filename_lower" | grep -q "$app_name_lower" && matched=1
                    ;;
                luci)
                    case "$filename_lower" in
                        luci-app-${app_name_lower}_*${PKG_EXT}|luci-app-${app_name_lower}-*${PKG_EXT}|\
                        luci-theme-${app_name_lower}_*${PKG_EXT}|luci-theme-${app_name_lower}-*${PKG_EXT})
                            matched=1 ;;
                    esac
                    ;;
                lang)
                    case "$filename_lower" in
                        *luci-i18n-*${app_name_lower}*zh-cn*${PKG_EXT}|*luci-i18n-*${app_name_lower}*zh_cn*${PKG_EXT})
                            matched=1 ;;
                    esac
                    ;;
            esac
            
            if [ $matched -eq 1 ]; then
                case "$pkg_type" in
                    arch) log "  [架构包] $filename (匹配: $arch)" ;;
                    luci) log "  [Luci包] $filename" ;;
                    lang) log "  [语言包] $filename" ;;
                esac
                download_and_install_single "$filename" && success_count=$((success_count + 1))
                IFS="$old_IFS"
                return 0
            fi
        done
        IFS="$old_IFS"
        return 1
    }
    log "  查找架构包..."
    for arch in $ARCH_FALLBACK; do
        find_package "arch" "$arch" && break
    done
    log "  查找Luci包..."
    find_package "luci"
    log "  查找语言包..."
    find_package "lang"
    
    IFS="$old_IFS"
    ASSETS_JSON_CACHE=""
    ASSET_FILENAMES=""
    
    if [ $success_count -gt 0 ]; then
        log "  ✓ 成功安装 $success_count 个文件"
        return 0
    else
        log "  ✗ 未安装任何文件"
        log "  架构列表: $ARCH_FALLBACK"
        log "  应用名: $app_name"
        return 1
    fi
}

# 统一的包处理函数
process_package() {
    local pkg="$1" check_version="${2:-0}" current_ver="$3"
    log "处理包: $pkg"
    for source_config in $API_SOURCES; do
        parse_source_config "$source_config"
        log "  平台: $platform ($owner/$pkg)"
        local releases_json=$(api_get_latest_release "$platform" "$owner" "$pkg")
        echo "$releases_json" | grep -q '\[' || {
            log "  ✗ 获取releases失败"
            continue
        }
        local latest_tag=$(echo "$releases_json" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)
        
        [ -z "$latest_tag" ] && { log "  ✗ 未找到版本"; continue; }
        
        log "  最新版本: $latest_tag"
        if [ "$check_version" = "1" ]; then
            version_greater "$latest_tag" "$current_ver" || { 
                log "  ○ 当前版本已是最新 ($current_ver)"
                return 2
            }
            log "  发现新版本: $current_ver → $latest_tag"
        fi
        echo "$releases_json" | grep -q '"assets"' || { log "  ✗ 无assets"; continue; }
        if match_and_download "$releases_json" "$pkg" "$platform"; then
            log "  ✓ $pkg 安装成功"
            return 0
        else
            log "  ✗ 安装失败"
        fi
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
    INSTALLED_PACKAGES=""
    FAILED_PACKAGES=""
    for pkg in $packages; do
        log ""
        if process_package "$pkg" 0; then
            INSTALLED_PACKAGES="$INSTALLED_PACKAGES $pkg"
        else
            FAILED_PACKAGES="$FAILED_PACKAGES $pkg"
        fi
    done
    [ -n "$INSTALLED_PACKAGES" ] && save_third_party_to_config "$INSTALLED_PACKAGES"
    log ""
    log "安装汇总: 成功 $(echo $INSTALLED_PACKAGES | wc -w), 失败 $(echo $FAILED_PACKAGES | wc -w)"
    if [ -n "$INSTALLED_PACKAGES" ] || [ -n "$FAILED_PACKAGES" ]; then
        local report=$(generate_report "install")
        log ""
        log "$report"
        send_push "$DEVICE_MODEL - 包安装结果" "$report"
    fi
    # 返回失败状态给 auto-setup
    [ -z "$FAILED_PACKAGES" ] && return 0 || return 1
}

# 获取更新周期
get_update_schedule() {
    local c=$(crontab -l 2>/dev/null | grep "auto-update.sh" | grep -v "^#" | head -n1)
    [ -z "$c" ] && { echo "未设置"; return; }
    
    local m=$(echo "$c" | awk '{print $1}')
    local h=$(echo "$c" | awk '{print $2}')
    local d=$(echo "$c" | awk '{print $3}')
    local w=$(echo "$c" | awk '{print $5}')
    
    # 时间格式化
    local t=""
    if [ "$h" != "*" ] && ! echo "$h" | grep -q "/"; then
        t=$(printf " %02d" "$h")
        [ "$m" != "*" ] && ! echo "$m" | grep -q "/" && t=$(printf " %02d:%02d" "$h" "$m") || t="${t}点"
    fi
    
    # 星期
    local wn=$(echo "$w" | sed 's/0/周日/;s/1/周一/;s/2/周二/;s/3/周三/;s/4/周四/;s/5/周五/;s/6/周六/;s/7/周日/')
    
    # 判断（单行返回）
    [ "$w" != "*" ] && [ "$wn" != "$w" ] && { echo "每${wn}${t}"; return; }
    echo "$h" | grep -q "^\*/" && { echo "每$(echo $h | sed 's#\*/##')小时"; return; }
    echo "$d" | grep -q "^\*/" && { echo "每$(echo $d | sed 's#\*/##')天${t}"; return; }
    [ "$h" != "*" ] && [ "$d" = "*" ] && { echo "每天${t}"; return; }
    echo "$m" | grep -q "^\*/" && { echo "每$(echo $m | sed 's#\*/##')分钟"; return; }
    [ "$d" != "*" ] && { echo "每月${d}号${t}"; return; }
    
    echo "$m $h $d * $w"
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
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        opkg list-installed | grep -q "^$1 "
    else
        apk info -e "$1" >/dev/null 2>&1
    fi
}

get_package_version() {
    case "$1" in
        list-installed)
            if echo "$PKG_INSTALL" | grep -q "opkg"; then
                opkg list-installed | grep "^$2 " | awk '{print $3}'
            else
                apk info "$2" 2>/dev/null | grep "^$2-" | sed "s/^$2-//" | cut -d'-' -f1
            fi
            ;;
        list)
            if echo "$PKG_INSTALL" | grep -q "opkg"; then
                opkg list | grep "^$2 " | awk '{print $3}'
            else
                apk search "$2" 2>/dev/null | grep "^$2-" | sed "s/^$2-//" | cut -d'-' -f1
            fi
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
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        PKG_UPDATE="opkg update"
    else
        PKG_UPDATE="apk update"
    fi
    $PKG_UPDATE >>"$LOG_FILE" 2>&1 || { log "✗ 软件源更新失败"; return 1; }
    log "✓ 软件源更新成功"
    OFFICIAL_PACKAGES=""
    NON_OFFICIAL_PACKAGES=""
    EXCLUDED_COUNT=0
    local pkgs=""
    if echo "$PKG_INSTALL" | grep -q "opkg"; then
        pkgs=$(opkg list-installed | awk '{print $1}' | grep -v "^luci-i18n-")
    else
        pkgs=$(apk info 2>/dev/null | grep -v "^luci-i18n-")
    fi
    local total=$(echo "$pkgs" | wc -l)
    log "检测到 $total 个已安装包（已排除语言包）"
    local third_party_lower=$(to_lower "$THIRD_PARTY_INSTALLED")
    for pkg in $pkgs; do
        local pkg_lower=$(to_lower "$pkg")
        if echo " $third_party_lower " | grep -q " $pkg_lower "; then
            NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
        elif is_package_excluded "$pkg"; then
            EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
        elif echo "$PKG_INSTALL" | grep -q "opkg"; then
            if opkg info "$pkg" 2>/dev/null | grep -q "^Description:"; then
                OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg"
            else
                NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
            fi
        else
            if apk info "$pkg" 2>/dev/null | grep -q "^origin:"; then
                OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg"
            else
                NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
            fi
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
                if opkg upgrade "$pkg" >>"$LOG_FILE" 2>&1; then
                    log "  ✓ 升级成功"
                    UPDATED_PACKAGES="${UPDATED_PACKAGES}\n    - $pkg: $cur → $new"
                    OFFICIAL_UPDATED=$((OFFICIAL_UPDATED + 1))
                    install_language_package "$pkg"
                else
                    log "  ✗ 升级失败"
                    FAILED_PACKAGES="${FAILED_PACKAGES}\n    - $pkg"
                    OFFICIAL_FAILED=$((OFFICIAL_FAILED + 1))
                fi
            else
                if apk upgrade "$pkg" >>"$LOG_FILE" 2>&1; then
                    log "  ✓ 升级成功"
                    UPDATED_PACKAGES="${UPDATED_PACKAGES}\n    - $pkg: $cur → $new"
                    OFFICIAL_UPDATED=$((OFFICIAL_UPDATED + 1))
                else
                    log "  ✗ 升级失败"
                    FAILED_PACKAGES="${FAILED_PACKAGES}\n    - $pkg"
                    OFFICIAL_FAILED=$((OFFICIAL_FAILED + 1))
                fi
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
        local pkg_lower=$(to_lower "$pkg")
        local original_pkg=""
        
        for saved_pkg in $THIRD_PARTY_INSTALLED; do
            local saved_pkg_lower=$(to_lower "$saved_pkg")
            if [ "$pkg_lower" = "$saved_pkg_lower" ]; then
                original_pkg="$saved_pkg"
                break
            fi
        done
        [ -z "$original_pkg" ] && original_pkg="$pkg"
        local cur=$(get_package_version list-installed "$pkg")
        log "🔍 检查 $original_pkg (当前版本: $cur)"
        process_package "$original_pkg" 1 "$cur"
        local ret=$?
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
    log "当前脚本版本: $SCRIPT_VERSION"
    local temp="/tmp/auto-update-new.sh"
    local current_script=$(readlink -f "$0")
    for source_config in $API_SOURCES; do
        parse_source_config "$source_config"
        local script_url=""
        case "$platform" in
            gitcode) script_url="https://raw.gitcode.com/${repo}/raw/${branch}/auto-update.sh" ;;
            gitee)   script_url="https://gitee.com/${repo}/raw/${branch}/auto-update.sh" ;;
            *)       log "  ⚠ 不支持的平台: $platform"; continue ;;
        esac
        curl -fsSL -o "$temp" "$script_url" 2>/dev/null || {
            continue
        }
        if ! grep -q "run_update" "$temp"; then
            log "  ✗ 下载不完整: $platform"
            rm -f "$temp"
            continue
        fi
        local remote_ver=$(grep -o 'SCRIPT_VERSION="[^"]*"' "$temp" | head -1 | cut -d'"' -f2)
        if [ -z "$remote_ver" ]; then
            log "  ✗ 无法获取版本号: $platform"
            continue
        fi
        if [ "$SCRIPT_VERSION" = "$remote_ver" ]; then
            return 0
        fi
        if version_greater "$remote_ver" "$SCRIPT_VERSION"; then
            log "↻ 发现新版本: $SCRIPT_VERSION → $remote_ver"

            if mv "$temp" "$current_script" && chmod +x "$current_script"; then
                log "✓ 脚本更新成功！版本: $SCRIPT_VERSION → $remote_ver, 来源: $platform"
                exec "$current_script" "$@"
            else
                log "✗ 脚本替换失败"
                rm -f "$temp"
                return 1
            fi
        else
            log "○ 当前版本较新，无需更新"
            rm -f "$temp"
            return 0
        fi
    done
    return 1
}

# 报告生成
generate_report() {
    local mode="$1" r="" schedule=$(get_update_schedule)
    local strategy=$([ "$INSTALL_PRIORITY" = "1" ] && echo "官方源优先" || echo "第三方源优先")
    a() { r="${r}$1\n"; }
    # 模式特定内容
    if [ "$mode" = "install" ]; then
        local sc=$(echo $INSTALLED_PACKAGES | wc -w) fc=$(echo $FAILED_PACKAGES | wc -w)
        a "📦 包安装结果"; a "=================="; a "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        a "设备: $DEVICE_MODEL"; a "版本: v$SCRIPT_VERSION"; a ""
        a "安装结果:"; [ $sc -gt 0 ] && a "  ✓ 成功: $sc 个"
        [ $fc -gt 0 ] && a "  ✗ 失败: $fc 个（将由官方源安装）"; a ""
        if [ $sc -gt 0 ]; then a "已安装:"; for p in $INSTALLED_PACKAGES; do a "  - $p"; done; a ""; fi
        if [ $fc -gt 0 ]; then a "未找到仓库:"; for p in $FAILED_PACKAGES; do a "  - $p"; done; a ""; fi
    else
        local noc=$(echo $NON_OFFICIAL_PACKAGES | wc -w)
        a "脚本版本: $SCRIPT_VERSION"; a "=================="; a "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        a "设备: $DEVICE_MODEL"; a "策略: $strategy"; a ""
        a "官方源检查完成:"; a "  ✓ 升级: $OFFICIAL_UPDATED 个"
        [ -n "$UPDATED_PACKAGES" ] && a "$UPDATED_PACKAGES"
        a "  ○ 已是最新: $OFFICIAL_SKIPPED 个"; a "  ⊗ 不在官方源: $noc 个"
        a "  ⊝ 排除: $EXCLUDED_COUNT 个"; a "  ✗ 失败: $OFFICIAL_FAILED 个"
        [ -n "$FAILED_PACKAGES" ] && a "$FAILED_PACKAGES"; a ""
        a "第三方源检查完成:"; a "  ✓ 已更新: $THIRDPARTY_UPDATED 个"
        a "  ○ 已是最新: $THIRDPARTY_SAME 个"; a "  ✗ 失败: $THIRDPARTY_FAILED 个"; a ""
        [ $((OFFICIAL_UPDATED + THIRDPARTY_UPDATED)) -eq 0 ] && a "[提示] 所有软件包均为最新版本" && a ""
    fi
    
    # 通用部分
    a "⏰ 自动更新: $([ "$schedule" != "未设置" ] && echo "已启用" || echo "未设置")"
    [ "$schedule" != "未设置" ] && { a "  - 更新时间: ${schedule}"; a "  - 安装策略: ${strategy}"; }
    
    if [ -n "$THIRD_PARTY_INSTALLED" ]; then
        a ""; a "📦 第三方包: $(echo "$THIRD_PARTY_INSTALLED" | wc -w) 个"
        for pkg in $THIRD_PARTY_INSTALLED; do
            if [ "$mode" = "install" ] && echo " $INSTALLED_PACKAGES " | grep -q " $pkg "; then
                a "  - $pkg 🆕"
            else
                a "  - $pkg"
            fi
        done
    fi
    
    a ""; a "=================="; a "详细日志: $LOG_FILE"
    echo "$r"
}

# update模式
run_update() {
    rm -f "$LOG_FILE"
    touch "$LOG_FILE"
    log "OpenWrt 自动更新脚本 v${SCRIPT_VERSION}"
    log "开始执行 (PID: $$)"
    log "日志文件: $LOG_FILE"
    local conf="/etc/auto-setup.conf"
    [ -f "$conf" ] && . "$conf"
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
    local report=$(generate_report "update")
    log ""
    log "$report"
    send_push "$PUSH_TITLE" "$report"
}

# 参数处理
case "$1" in
    install) shift; run_install "$@" ;;
    *) run_update ;;
esac
