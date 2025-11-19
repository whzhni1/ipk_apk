#!/bin/sh

SCRIPT_VERSION="2.2.0"
LOG_FILE="/tmp/auto-update.log"
CONFIG_FILE="/etc/auto-setup.conf"
DEVICE_MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo '未知设备')"
PUSH_TITLE="$DEVICE_MODEL 插件更新通知"

# 排除的包列表（不检查更新）
EXCLUDE_PACKAGES="kernel kmod- base-files busybox lib opkg uclient-fetch ca-bundle ca-certificates luci-app-lucky luci-app-openlist2 luci-app-tailscale"

# 日志输出函数
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
    logger -t "auto-update" "$1" 2>/dev/null || true
}

# 加载配置文件（包含所有包管理器命令）
load_config() {
    [ ! -f "$CONFIG_FILE" ] && { log "✗ 配置文件不存在: $CONFIG_FILE"; return 1; }
    
    . "$CONFIG_FILE"
    
    log "✓ 配置已加载"
    
    # 验证必需配置
    local missing=""
    for key in SYS_ARCH PKG_INSTALL PKG_UPDATE PKG_LIST_INSTALLED API_SOURCES; do
        eval "[ -z \"\$$key\" ]" && missing="$missing $key"
    done
    
    [ -n "$missing" ] && { log "✗ 缺少配置:$missing"; return 1; }
    return 0
}

# 解析源配置（平台|仓库|分支）
parse_source_config() {
    local source_config="$1"
    platform=$(echo "$source_config" | cut -d'|' -f1)
    repo=$(echo "$source_config" | cut -d'|' -f2)
    branch=$(echo "$source_config" | cut -d'|' -f3)
    owner=$(echo "$repo" | cut -d'/' -f1)
}

# 格式化文件大小
format_size() {
    local bytes="$1"
    [ $bytes -gt 1048576 ] && echo "$((bytes / 1048576)) MB" && return
    [ $bytes -gt 1024 ] && echo "$((bytes / 1024)) KB" && return
    echo "$bytes 字节"
}

# 转小写
to_lower() {
    echo "$1" | tr 'A-Z' 'a-z'
}

# 验证下载的文件
validate_downloaded_file() {
    local filepath="$1" min_size="${2:-1024}"
    
    [ ! -f "$filepath" ] || [ ! -s "$filepath" ] && { log "  ✗ 文件不存在或为空"; return 1; }
    
    local size=$(wc -c < "$filepath" 2>/dev/null | tr -d ' ')
    [ "$size" -lt "$min_size" ] && head -1 "$filepath" 2>/dev/null | grep -qi "<!DOCTYPE\|<html" && {
        log "  ✗ 下载的是HTML页面"
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
    esac
}

# API 调用统一接口
api_call() {
    local url="$1" token="$2"
    [ -n "$token" ] && curl -s -H "Authorization: Bearer $token" "$url" || curl -s "$url"
}

# 获取最新 Release
api_get_latest_release() {
    local platform="$1" owner="$2" repo="$3"
    local token=$(get_token_for_platform "$platform")
    local api_url=""
    
    case "$platform" in
        gitee)
            api_url="https://gitee.com/api/v5/repos/${owner}/${repo}/releases"
            ;;
        gitcode)
            api_url="https://gitcode.com/api/v5/repos/${owner}/${repo}/releases"
            [ -z "$token" ] && { echo "[]"; return 1; }
            ;;
        *)
            return 1
            ;;
    esac
    
    api_call "$api_url" "$token"
}

# 标准化版本号
normalize_version() {
    echo "$1" | sed 's/^[vV]//' | sed 's/[-_].*//'
}

# 比较版本号大小
version_greater() {
    local v1=$(normalize_version "$1")
    local v2=$(normalize_version "$2")
    [ "$v1" = "$v2" ] && return 1
    test "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -1)" = "$v1"
}

# 提取应用名称
extract_app_name() {
    local pkg="$1"
    echo "$pkg" | sed 's/^luci-app-//' | sed 's/^luci-theme-//'
}

# 从 JSON 提取文件名列表
extract_filenames() {
    local json_data="$1"
    ASSETS_JSON_CACHE="$json_data"
    
    case "$PKG_EXT" in
        .ipk) ASSET_FILENAMES=$(echo "$json_data" | grep -o '"name":"[^"]*\.ipk"' | cut -d'"' -f4) ;;
        .apk) ASSET_FILENAMES=$(echo "$json_data" | grep -o '"name":"[^"]*\.apk"' | cut -d'"' -f4) ;;
        *) log "  ✗ 不支持的包格式: $PKG_EXT"; return 1 ;;
    esac
    
    [ -z "$ASSET_FILENAMES" ] && { log "  ✗ 未找到 $PKG_EXT 文件"; return 1; }
    
    local count=$(echo "$ASSET_FILENAMES" | wc -l)
    log "  找到 $count 个 $PKG_EXT 文件"
    return 0
}

# 根据文件名查找下载地址
get_download_url() {
    local filename="$1"
    local url=$(echo "$ASSETS_JSON_CACHE" | grep -o "https://[^\"]*${filename}" | head -1)
    echo "$url" | sed 's|https://api\.gitcode\.com/|https://gitcode.com/|'
}

# 获取所有文件名列表
get_all_filenames() {
    echo "$ASSET_FILENAMES"
}

# 下载并安装单个文件
download_and_install_single() {
    local filename="$1"
    local download_url=$(get_download_url "$filename")
    
    [ -z "$download_url" ] && { log "    ✗ 未找到下载地址: $filename"; return 1; }
    
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

# 匹配文件名
match_filename() {
    local filename="$1" app_name="$2" match_type="$3" arch="${4:-}"
    
    local fn_lower=$(to_lower "$filename")
    local app_lower=$(to_lower "$app_name")
    
    case "$match_type" in
        arch)
            # 架构包：不是 luci 开头，包含架构和应用名
            echo "$fn_lower" | grep -q "^luci-" && return 1
            echo "$fn_lower" | grep -q "$arch" || return 1
            echo "$fn_lower" | grep -q "$app_lower"
            ;;
        luci)
            # Luci 包：精确匹配
            case "$fn_lower" in
                luci-app-${app_lower}_*${PKG_EXT}|\
                luci-app-${app_lower}-*${PKG_EXT}|\
                luci-theme-${app_lower}_*${PKG_EXT}|\
                luci-theme-${app_lower}-*${PKG_EXT})
                    return 0 ;;
                *) return 1 ;;
            esac
            ;;
        lang)
            # 语言包
            echo "$fn_lower" | grep -Eq "luci-i18n-.*${app_lower}.*(zh-cn|zh_cn).*${PKG_EXT}$"
            ;;
        *)
            return 1
            ;;
    esac
}

# 查找并安装特定类型的包
find_and_install_package() {
    local all_files="$1" app_name="$2" pkg_type="$3"
    
    local IFS=$'\n'
    for filename in $all_files; do
        [ -z "$filename" ] && continue
        
        case "$pkg_type" in
            arch)
                # 尝试所有架构变体
                for arch in $ARCH_FALLBACK; do
                    if match_filename "$filename" "$app_name" "arch" "$arch"; then
                        log "  [架构包] $filename (匹配: $arch)"
                        download_and_install_single "$filename" && return 0
                    fi
                done
                ;;
            luci|lang)
                if match_filename "$filename" "$app_name" "$pkg_type"; then
                    local label=$([ "$pkg_type" = "luci" ] && echo "Luci包" || echo "语言包")
                    log "  [$label] $filename"
                    download_and_install_single "$filename" && return 0
                fi
                ;;
        esac
    done
    
    return 1
}

# 匹配并下载安装
match_and_download() {
    local assets_json="$1" pkg_name="$2" platform="$3"
    local app_name=$(extract_app_name "$pkg_name")
    
    log "  应用名: $app_name"
    
    extract_filenames "$assets_json" || return 1
    
    local all_files=$(get_all_filenames)
    local success=0
    
    # 按优先级安装：架构包 -> Luci包 -> 语言包
    find_and_install_package "$all_files" "$app_name" "arch" && success=$((success + 1))
    find_and_install_package "$all_files" "$app_name" "luci" && success=$((success + 1))
    find_and_install_package "$all_files" "$app_name" "lang" && success=$((success + 1))
    
    # 清理缓存
    ASSETS_JSON_CACHE=""
    ASSET_FILENAMES=""
    
    if [ $success -gt 0 ]; then
        log "  ✓ 成功安装 $success 个文件"
        return 0
    else
        log "  ✗ 未找到匹配文件"
        log "  架构列表: $ARCH_FALLBACK"
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
        
        # 检查版本（如果需要）
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

# 保存第三方安装包到配置文件
save_third_party_to_config() {
    local new_packages="$1"
    
    [ ! -f "$CONFIG_FILE" ] && { log "✗ 配置文件不存在"; return 1; }
    
    # 读取现有的第三方包列表
    local existing=$(sed -n 's/^THIRD_PARTY_INSTALLED="\(.*\)"/\1/p' "$CONFIG_FILE")
    
    # 合并去重
    local combined=$(echo "$existing $new_packages" | xargs | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)
    
    # 更新配置文件
    if grep -q "^THIRD_PARTY_INSTALLED=" "$CONFIG_FILE"; then
        sed -i "s|^THIRD_PARTY_INSTALLED=.*|THIRD_PARTY_INSTALLED=\"$combined\"|" "$CONFIG_FILE"
    else
        echo "" >> "$CONFIG_FILE"
        echo "# 第三方源安装的包" >> "$CONFIG_FILE"
        echo "THIRD_PARTY_INSTALLED=\"$combined\"" >> "$CONFIG_FILE"
    fi
    
    log "✓ 配置已更新: $combined"
}

# install 模式：从第三方源安装包
run_install() {
    local packages="$*"
    
    log "第三方源安装模式"
    log "包列表: $packages"
    
    load_config || return 1
    
    local installed="" failed=""
    local installed_count=0 failed_count=0
    
    for pkg in $packages; do
        log ""
        if process_package "$pkg" 0; then
            installed="$installed $pkg"
            installed_count=$((installed_count + 1))
        else
            failed="$failed $pkg"
            failed_count=$((failed_count + 1))
        fi
    done
    
    [ -n "$installed" ] && save_third_party_to_config "$installed"
    
    log ""
    log "安装汇总: 成功 $installed_count, 失败 $failed_count"
    
    if [ $installed_count -gt 0 ] || [ $failed_count -gt 0 ]; then
        local report=$(generate_report "install" "$installed" "$failed")
        log ""
        log "$report"
        send_push "$DEVICE_MODEL - 包安装结果" "$report"
    fi
    
    [ -z "$failed" ] && return 0 || return 1
}

# 获取更新周期描述
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
    
    local wn=$(echo "$w" | sed 's/0/周日/;s/1/周一/;s/2/周二/;s/3/周三/;s/4/周四/;s/5/周五/;s/6/周六/;s/7/周日/')
    
    # 判断周期
    [ "$w" != "*" ] && [ "$wn" != "$w" ] && { echo "每${wn}${t}"; return; }
    echo "$h" | grep -q "^\*/" && { echo "每$(echo $h | sed 's#\*/##')小时"; return; }
    echo "$d" | grep -q "^\*/" && { echo "每$(echo $d | sed 's#\*/##')天${t}"; return; }
    [ "$h" != "*" ] && [ "$d" = "*" ] && { echo "每天${t}"; return; }
    echo "$m" | grep -q "^\*/" && { echo "每$(echo $m | sed 's#\*/##')分钟"; return; }
    [ "$d" != "*" ] && { echo "每月${d}号${t}"; return; }
    echo "$m $h $d * $w"
}

# 检查包是否排除
is_package_excluded() {
    case "$1" in luci-i18n-*) return 0 ;; esac
    for pattern in $EXCLUDE_PACKAGES; do
        case "$1" in $pattern*) return 0 ;; esac
    done
    return 1
}

# 检查包是否已安装
is_installed() {
    $PKG_LIST_INSTALLED 2>/dev/null | grep -q "^$1 "
}

# 获取包版本（统一接口）
get_package_version() {
    local pkg="$1" source="${2:-installed}"
    
    case "$source" in
        installed)
            $PKG_LIST_INSTALLED 2>/dev/null | awk -v p="$pkg" '$1==p {print $3; exit}'
            ;;
        *)
            $PKG_LIST 2>/dev/null "$pkg" | awk -v p="$pkg" '$1==p {print $3; exit}'
            ;;
    esac
}

# 安装语言包
install_language_package() {
    local pkg="$1"
    local lang_pkg=""
    
    case "$pkg" in
        luci-app-*) lang_pkg="luci-i18n-${pkg#luci-app-}-zh-cn" ;;
        luci-theme-*) lang_pkg="luci-i18n-theme-${pkg#luci-theme-}-zh-cn" ;;
        *) return 0 ;;
    esac
    
    # 检查语言包是否存在
    $PKG_LIST "$lang_pkg" 2>/dev/null | grep -q "^$lang_pkg " || return 0
    
    local action=$(is_installed "$lang_pkg" && echo "升级" || echo "安装")
    log "    ${action}语言包 $lang_pkg..."
    
    $PKG_INSTALL "$lang_pkg" >>"$LOG_FILE" 2>&1 && \
        log "    ✓ $lang_pkg ${action}成功" || \
        log "    ⚠ $lang_pkg ${action}失败"
}

# 分类已安装的包
classify_packages() {
    log "步骤: 分类已安装的包"
    log "更新软件源..."
    
    $PKG_UPDATE >>"$LOG_FILE" 2>&1 || { log "✗ 软件源更新失败"; return 1; }
    
    log "✓ 软件源更新成功"
    
    OFFICIAL_PACKAGES=""
    NON_OFFICIAL_PACKAGES=""
    local excluded_count=0
    
    # 获取所有已安装包（排除语言包）
    local pkgs=$($PKG_LIST_INSTALLED 2>/dev/null | awk '{print $1}' | grep -v "^luci-i18n-")
    local total=$(echo "$pkgs" | wc -l)
    
    log "检测到 $total 个已安装包（已排除语言包）"
    
    local third_party_lower=$(to_lower "$THIRD_PARTY_INSTALLED")
    
    for pkg in $pkgs; do
        local pkg_lower=$(to_lower "$pkg")
        
        # 检查是否在第三方列表
        if echo " $third_party_lower " | grep -q " $pkg_lower "; then
            NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
        elif is_package_excluded "$pkg"; then
            excluded_count=$((excluded_count + 1))
        else
            # 检查是否在官方源
            $PKG_LIST "$pkg" 2>/dev/null | grep -q "^$pkg " && \
                OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg" || \
                NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
        fi
    done
    
    log "包分类完成: 官方源 $(echo $OFFICIAL_PACKAGES | wc -w), 第三方源 $(echo $NON_OFFICIAL_PACKAGES | wc -w), 排除 $excluded_count"
    return 0
}

# 更新官方源的包
update_official_packages() {
    log "步骤: 更新官方源中的包"
    
    local updated_count=0 skipped_count=0 failed_count=0
    local updated_list="" failed_list=""
    
    for pkg in $OFFICIAL_PACKAGES; do
        local cur=$(get_package_version "$pkg" installed)
        local new=$(get_package_version "$pkg" available)
        
        if [ "$cur" != "$new" ] && [ -n "$new" ]; then
            log "↻ $pkg: $cur → $new"
            
            if $PKG_INSTALL "$pkg" >>"$LOG_FILE" 2>&1; then
                log "  ✓ 升级成功"
                updated_list="${updated_list}\n    - $pkg: $cur → $new"
                updated_count=$((updated_count + 1))
                install_language_package "$pkg"
            else
                log "  ✗ 升级失败"
                failed_list="${failed_list}\n    - $pkg"
                failed_count=$((failed_count + 1))
            fi
        else
            log "○ $pkg: $cur (已是最新)"
            skipped_count=$((skipped_count + 1))
        fi
    done
    
    UPDATED_PACKAGES="$updated_list"
    FAILED_PACKAGES="$failed_list"
    OFFICIAL_UPDATED=$updated_count
    OFFICIAL_SKIPPED=$skipped_count
    OFFICIAL_FAILED=$failed_count
    
    log "官方源检查完成: 升级 $updated_count, 已是最新 $skipped_count, 失败 $failed_count"
    return 0
}

# 更新第三方源的包
update_thirdparty_packages() {
    log "步骤: 检查并更新第三方源的包"
    
    local updated_count=0 same_count=0 failed_count=0
    local check_list=""
    
    # 只检查 luci 插件和主题
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
        
        # 在保存的列表中查找原始大小写
        for saved_pkg in $THIRD_PARTY_INSTALLED; do
            local saved_pkg_lower=$(to_lower "$saved_pkg")
            if [ "$pkg_lower" = "$saved_pkg_lower" ]; then
                original_pkg="$saved_pkg"
                break
            fi
        done
        
        [ -z "$original_pkg" ] && original_pkg="$pkg"
        
        local cur=$(get_package_version "$pkg" installed)
        log "🔍 检查 $original_pkg (当前版本: $cur)"
        
        process_package "$original_pkg" 1 "$cur"
        local ret=$?
        
        case $ret in
            0) updated_count=$((updated_count + 1)) ;;
            2) same_count=$((same_count + 1)) ;;
            *) failed_count=$((failed_count + 1)) ;;
        esac
    done
    
    THIRDPARTY_UPDATED=$updated_count
    THIRDPARTY_SAME=$same_count
    THIRDPARTY_FAILED=$failed_count
    
    log "第三方源检查完成: 已更新 $updated_count, 已是最新 $same_count, 失败 $failed_count"
    return 0
}

# 检查脚本更新
check_script_update() {
    log "当前脚本版本: $SCRIPT_VERSION"
    
    local temp="/tmp/auto-update-new.sh"
    local current_script=$(readlink -f "$0")
    
    for source_config in $API_SOURCES; do
        parse_source_config "$source_config"
        
        local script_url=""
        case "$platform" in
            gitcode) script_url="https://raw.gitcode.com/${repo}/raw/${branch}/auto-update.sh" ;;
            gitee) script_url="https://gitee.com/${repo}/raw/${branch}/auto-update.sh" ;;
            *) log "  ⚠ 不支持的平台: $platform"; continue ;;
        esac
        
        curl -fsSL -o "$temp" "$script_url" 2>/dev/null || continue
        
        grep -q "run_update" "$temp" || {
            log "  ✗ 下载不完整: $platform"
            rm -f "$temp"
            continue
        }
        
        local remote_ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$temp" | head -1)
        [ -z "$remote_ver" ] && { log "  ✗ 无法获取版本号"; continue; }
        
        [ "$SCRIPT_VERSION" = "$remote_ver" ] && { rm -f "$temp"; return 0; }
        
        if version_greater "$remote_ver" "$SCRIPT_VERSION"; then
            log "↻ 发现新版本: $SCRIPT_VERSION → $remote_ver"
            
            if mv "$temp" "$current_script" && chmod +x "$current_script"; then
                log "✓ 脚本更新成功，版本: $remote_ver, 来源: $platform"
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

# 推送通知
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

# 生成报告
generate_report() {
    local mode="$1" installed="$2" failed="$3"
    local r="" schedule=$(get_update_schedule)
    local strategy=$([ "$INSTALL_PRIORITY" = "1" ] && echo "官方源优先" || echo "第三方源优先")
    
    if [ "$mode" = "install" ]; then
        local sc=$(echo $installed | wc -w) fc=$(echo $failed | wc -w)
        r="${r}📦 包安装结果\n"
        r="${r}时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
        r="${r}设备: $DEVICE_MODEL\n"
        r="${r}版本: v$SCRIPT_VERSION\n\n"
        r="${r}安装结果:\n"
        [ $sc -gt 0 ] && r="${r}  ✓ 成功: $sc 个\n"
        [ $fc -gt 0 ] && r="${r}  ✗ 失败: $fc 个\n\n"
        
        if [ $sc -gt 0 ]; then
            r="${r}已安装:\n"
            for p in $installed; do r="${r}  - $p\n"; done
            r="${r}\n"
        fi
        
        if [ $fc -gt 0 ]; then
            r="${r}失败:\n"
            for p in $failed; do r="${r}  - $p\n"; done
            r="${r}\n"
        fi
    else
        local noc=$(echo $NON_OFFICIAL_PACKAGES | wc -w)
        r="${r}脚本版本: $SCRIPT_VERSION\n"
        r="${r}时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
        r="${r}设备: $DEVICE_MODEL\n"
        r="${r}策略: $strategy\n\n"
        r="${r}官方源检查完成:\n"
        r="${r}  ✓ 升级: $OFFICIAL_UPDATED 个\n"
        [ -n "$UPDATED_PACKAGES" ] && r="${r}$UPDATED_PACKAGES\n"
        r="${r}  ○ 已是最新: $OFFICIAL_SKIPPED 个\n"
        r="${r}  ⊗ 不在官方源: $noc 个\n"
        r="${r}  ✗ 失败: $OFFICIAL_FAILED 个\n"
        [ -n "$FAILED_PACKAGES" ] && r="${r}$FAILED_PACKAGES\n"
        r="${r}\n"
        r="${r}第三方源检查完成:\n"
        r="${r}  ✓ 已更新: $THIRDPARTY_UPDATED 个\n"
        r="${r}  ○ 已是最新: $THIRDPARTY_SAME 个\n"
        r="${r}  ✗ 失败: $THIRDPARTY_FAILED 个\n\n"
        [ $((OFFICIAL_UPDATED + THIRDPARTY_UPDATED)) -eq 0 ] && r="${r}[提示] 所有软件包均为最新版本\n\n"
    fi
    
    r="${r}⏰ 自动更新: $([ "$schedule" != "未设置" ] && echo "已启用" || echo "未设置")\n"
    [ "$schedule" != "未设置" ] && {
        r="${r}  - 更新时间: ${schedule}\n"
        r="${r}  - 安装策略: ${strategy}\n"
    }
    
    if [ -n "$THIRD_PARTY_INSTALLED" ]; then
        r="${r}\n📦 第三方包: $(echo "$THIRD_PARTY_INSTALLED" | wc -w) 个\n"
        for pkg in $THIRD_PARTY_INSTALLED; do
            if [ "$mode" = "install" ] && echo " $installed " | grep -q " $pkg "; then
                r="${r}  - $pkg 🆕\n"
            else
                r="${r}  - $pkg\n"
            fi
        done
    fi
    
    r="${r}\n详细日志: $LOG_FILE"
    echo "$r"
}

# update 模式：检查并更新所有包
run_update() {
    # ✅ 每次运行覆盖日志
    > "$LOG_FILE"
    
    log "OpenWrt 自动更新脚本 v${SCRIPT_VERSION}"
    log "开始执行 (PID: $$)"
    log "日志文件: $LOG_FILE"
    
    load_config || return 1
    
    log "系统架构: $SYS_ARCH"
    log "包管理器: $PKG_TYPE"
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
    
    log "✓ 更新流程完成"
    
    local report=$(generate_report "update")
    log ""
    log "$report"
    
    send_push "$PUSH_TITLE" "$report"
}

# 主入口
case "$1" in
    install) shift; run_install "$@" ;;
    *) run_update ;;
esac
