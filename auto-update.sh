#!/bin/sh

SCRIPT_VERSION="2.2.0"
LOG_FILE="/tmp/auto-update.log"
CONFIG_FILE="/etc/auto-setup.conf"
DEVICE_MODEL="$(cat /tmp/sysinfo/model 2>/dev/null || echo '未知设备')"
PUSH_TITLE="$DEVICE_MODEL 插件更新通知"
EXCLUDE_PACKAGES="kernel kmod- base-files busybox lib opkg uclient-fetch ca-bundle ca-certificates luci-app-lucky luci-app-openlist2 luci-app-tailscale"

# 批量初始化变量
for var in ASSETS_JSON_CACHE INSTALLED_LIST FAILED_LIST OFFICIAL_PACKAGES NON_OFFICIAL_PACKAGES UPDATED_PACKAGES FAILED_PACKAGES; do
    eval "$var=''"
done

for var in OFFICIAL_UPDATED OFFICIAL_SKIPPED OFFICIAL_FAILED THIRDPARTY_UPDATED THIRDPARTY_SAME THIRDPARTY_FAILED; do
    eval "$var=0"
done

# 日志函数
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
    logger -t "auto-update" "$1" 2>/dev/null || true
}

# 加载配置
load_config() {
    [ ! -f "$CONFIG_FILE" ] && { log "✗ 配置文件不存在"; return 1; }
    . "$CONFIG_FILE"
    
    for key in SYS_ARCH PKG_INSTALL PKG_UPDATE PKG_LIST_INSTALLED API_SOURCES; do
        eval "[ -z \"\$$key\" ]" && { log "✗ 缺少配置: $key"; return 1; }
    done
    
    log "✓ 配置已加载"
}

# 解析源配置
parse_source_config() {
    platform=$(echo "$1" | cut -d'|' -f1)
    repo=$(echo "$1" | cut -d'|' -f2)
    branch=$(echo "$1" | cut -d'|' -f3)
    owner=$(echo "$repo" | cut -d'/' -f1)
}

# 工具函数
to_lower() { echo "$1" | tr 'A-Z' 'a-z'; }
normalize_version() { echo "$1" | sed 's/^[vV]//' | sed 's/[-_].*//'; }
format_size() {
    local b="$1"
    [ $b -gt 1048576 ] && echo "$((b/1048576)) MB" && return
    [ $b -gt 1024 ] && echo "$((b/1024)) KB" && return
    echo "$b 字节"
}

# 版本比较
version_greater() {
    local v1=$(normalize_version "$1") v2=$(normalize_version "$2")
    [ "$v1" = "$v2" ] && return 1
    [ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -1)" = "$v1" ]
}

# 验证下载文件
validate_file() {
    local file="$1" min="${2:-1024}"
    [ ! -f "$file" ] || [ ! -s "$file" ] && { log "  ✗ 文件无效"; return 1; }
    
    local size=$(wc -c < "$file" | tr -d ' ')
    [ $size -lt $min ] && head -1 "$file" | grep -qi "<!DOCTYPE\|<html" && {
        log "  ✗ 下载的是HTML"
        return 1
    }
    
    log "  ✓ 文件有效: $(format_size $size)"
}

# API 调用
api_get_release() {
    local platform="$1" owner="$2" repo="$3"
    local token=""
    
    case "$platform" in
        gitee) token="$GITEE_TOKEN" ;;
        gitcode) token="$GITCODE_TOKEN"; [ -z "$token" ] && return 1 ;;
        *) return 1 ;;
    esac
    
    local url="https://${platform}.com/api/v5/repos/${owner}/${repo}/releases"
    [ -n "$token" ] && curl -s -H "Authorization: Bearer $token" "$url" || curl -s "$url"
}

# 提取文件名
extract_filenames() {
    ASSETS_JSON_CACHE="$1"
    local pattern=$([ "$PKG_EXT" = ".ipk" ] && echo "\.ipk" || echo "\.apk")
    local files=$(echo "$1" | grep -o "\"name\":\"[^\"]*${pattern}\"" | cut -d'"' -f4)
    [ -z "$files" ] && { log "  ✗ 未找到 $PKG_EXT 文件"; return 1; }
    log "  找到 $(echo "$files" | wc -l) 个文件"
    echo "$files"
}

# 获取下载地址
get_download_url() {
    echo "$ASSETS_JSON_CACHE" | grep -o "https://[^\"]*$1" | head -1 | sed 's|api\.gitcode\.com/|gitcode.com/|'
}

# 下载并安装
download_and_install() {
    local file="$1"
    local url=$(get_download_url "$file")
    [ -z "$url" ] && { log "    ✗ 无下载地址"; return 1; }
    
    log "    下载: $file"
    curl -fsSL -o "/tmp/$file" "$url" || { log "    ✗ 下载失败"; return 1; }
    
    validate_file "/tmp/$file" 10240 || { rm -f "/tmp/$file"; return 1; }
    
    log "    安装: $file"
    $PKG_INSTALL "/tmp/$file" >>"$LOG_FILE" 2>&1 && {
        log "    ✓ 安装成功"
        rm -f "/tmp/$file"
        return 0
    } || {
        log "    ✗ 安装失败: $(tail -1 "$LOG_FILE" | grep -v '^\[')"
        return 1
    }
}

# 匹配文件名
match_file() {
    local file="$1" app="$2" type="$3" arch="${4:-}"
    local fl=$(to_lower "$file") al=$(to_lower "$app")
    
    case "$type" in
        arch)
            echo "$fl" | grep -q "^luci-" && return 1
            echo "$fl" | grep -q "$arch" && echo "$fl" | grep -q "$al"
            ;;
        luci)
            echo "$fl" | grep -Eq "^luci-(app|theme)-${al}[-_].*${PKG_EXT}$"
            ;;
        lang)
            echo "$fl" | grep -Eq "luci-i18n-.*${al}.*(zh-cn|zh_cn).*${PKG_EXT}$"
            ;;
    esac
}

# 查找并安装
find_and_install() {
    local files="$1" app="$2" type="$3"
    local IFS=$'\n'
    
    for file in $files; do
        [ -z "$file" ] && continue
        
        if [ "$type" = "arch" ]; then
            for arch in $ARCH_FALLBACK; do
                match_file "$file" "$app" "arch" "$arch" && {
                    log "  [架构包] $file ($arch)"
                    download_and_install "$file" && return 0
                }
            done
        else
            match_file "$file" "$app" "$type" && {
                local label=$([ "$type" = "luci" ] && echo "Luci包" || echo "语言包")
                log "  [$label] $file"
                download_and_install "$file" && return 0
            }
        fi
    done
    
    return 1
}

# 处理单个包
process_package() {
    local pkg="$1" check_ver="${2:-0}" cur_ver="$3"
    log "处理包: $pkg"
    
    local app=$(echo "$pkg" | sed 's/^luci-app-//' | sed 's/^luci-theme-//')
    
    for src in $API_SOURCES; do
        parse_source_config "$src"
        log "  平台: $platform ($owner/$pkg)"
        
        local json=$(api_get_release "$platform" "$owner" "$pkg")
        echo "$json" | grep -q '\[' || { log "  ✗ API调用失败"; continue; }
        
        local ver=$(echo "$json" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)
        [ -z "$ver" ] && { log "  ✗ 无版本信息"; continue; }
        log "  最新版本: $ver"
        
        if [ "$check_ver" = "1" ]; then
            version_greater "$ver" "$cur_ver" || { log "  ○ 已是最新 ($cur_ver)"; return 2; }
            log "  发现更新: $cur_ver → $ver"
        fi
        
        echo "$json" | grep -q '"assets"' || { log "  ✗ 无资源文件"; continue; }
        
        local files=$(extract_filenames "$json") || continue
        local count=0
        
        find_and_install "$files" "$app" "arch" && count=$((count+1))
        find_and_install "$files" "$app" "luci" && count=$((count+1))
        find_and_install "$files" "$app" "lang" && count=$((count+1))
        
        ASSETS_JSON_CACHE=""
        
        [ $count -gt 0 ] && { log "  ✓ 安装成功 ($count 个文件)"; return 0; }
        log "  ✗ 无匹配文件"
    done
    
    log "✗ 所有源均失败"
    return 1
}

# 保存第三方包列表
save_third_party() {
    [ ! -f "$CONFIG_FILE" ] && return
    local old=$(sed -n 's/^THIRD_PARTY_INSTALLED="\(.*\)"/\1/p' "$CONFIG_FILE")
    local new=$(echo "$old $1" | xargs | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)
    
    grep -q "^THIRD_PARTY_INSTALLED=" "$CONFIG_FILE" && \
        sed -i "s|^THIRD_PARTY_INSTALLED=.*|THIRD_PARTY_INSTALLED=\"$new\"|" "$CONFIG_FILE" || \
        printf '\n# 第三方源安装的包\nTHIRD_PARTY_INSTALLED="%s"\n' "$new" >> "$CONFIG_FILE"
    
    log "✓ 配置已更新"
}

# install 模式（auto-setup 已过滤已安装，这里不再检查）
run_install() {
    log "第三方源安装模式"
    log "包列表: $*"
    
    load_config || return 1
    
    local success=0 failed=0
    
    for pkg in "$@"; do
        log ""
        if process_package "$pkg" 0; then
            INSTALLED_LIST="$INSTALLED_LIST $pkg"
            success=$((success+1))
        else
            FAILED_LIST="$FAILED_LIST $pkg"
            failed=$((failed+1))
        fi
    done
    
    INSTALLED_LIST=$(echo "$INSTALLED_LIST" | xargs)
    FAILED_LIST=$(echo "$FAILED_LIST" | xargs)
    
    [ -n "$INSTALLED_LIST" ] && save_third_party "$INSTALLED_LIST"
    
    log ""
    log "安装汇总: 成功 $success, 失败 $failed"
    
    if [ $success -gt 0 ] || [ $failed -gt 0 ]; then
        generate_report "install"
        log ""
        echo "$REPORT"
        send_push "$DEVICE_MODEL - 包安装结果" "$REPORT"
    fi
    
    [ $failed -eq 0 ]
}

# update 模式需要检查已安装
is_installed() {
    $PKG_LIST_INSTALLED 2>/dev/null | grep -q "^$1 "
}

is_excluded() {
    case "$1" in luci-i18n-*) return 0 ;; esac
    for p in $EXCLUDE_PACKAGES; do case "$1" in $p*) return 0 ;; esac; done
    return 1
}

get_version() {
    local pkg="$1" src="${2:-installed}"
    [ "$src" = "installed" ] && \
        $PKG_LIST_INSTALLED 2>/dev/null | awk -v p="$pkg" '$1==p {print $3; exit}' || \
        $PKG_LIST "$pkg" 2>/dev/null | awk -v p="$pkg" '$1==p {print $3; exit}'
}

install_lang() {
    local pkg="$1" lang=""
    case "$pkg" in
        luci-app-*) lang="luci-i18n-${pkg#luci-app-}-zh-cn" ;;
        luci-theme-*) lang="luci-i18n-theme-${pkg#luci-theme-}-zh-cn" ;;
        *) return ;;
    esac
    
    $PKG_LIST "$lang" 2>/dev/null | grep -q "^$lang " || return
    $PKG_INSTALL "$lang" >>"$LOG_FILE" 2>&1 && log "    ✓ $lang 安装成功"
}

# 分类包
classify_packages() {
    log "步骤: 分类已安装的包"
    $PKG_UPDATE >>"$LOG_FILE" 2>&1 || { log "✗ 更新源失败"; return 1; }
    log "✓ 软件源已更新"
    
    local all=$($PKG_LIST_INSTALLED 2>/dev/null | awk '{print $1}' | grep -v "^luci-i18n-")
    local third_lower=$(to_lower "$THIRD_PARTY_INSTALLED")
    local excluded=0
    
    for pkg in $all; do
        echo " $third_lower " | grep -q " $(to_lower "$pkg") " && {
            NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
        } || is_excluded "$pkg" && {
            excluded=$((excluded+1))
        } || $PKG_LIST "$pkg" 2>/dev/null | grep -q "^$pkg " && {
            OFFICIAL_PACKAGES="$OFFICIAL_PACKAGES $pkg"
        } || {
            NON_OFFICIAL_PACKAGES="$NON_OFFICIAL_PACKAGES $pkg"
        }
    done
    
    log "包分类: 官方 $(echo $OFFICIAL_PACKAGES|wc -w), 第三方 $(echo $NON_OFFICIAL_PACKAGES|wc -w), 排除 $excluded"
}

# 更新官方包
update_official() {
    log "步骤: 更新官方源"
    
    for pkg in $OFFICIAL_PACKAGES; do
        local cur=$(get_version "$pkg" installed)
        local new=$(get_version "$pkg" available)
        
        [ "$cur" != "$new" ] && [ -n "$new" ] && {
            log "↻ $pkg: $cur → $new"
            $PKG_INSTALL "$pkg" >>"$LOG_FILE" 2>&1 && {
                log "  ✓ 升级成功"
                UPDATED_PACKAGES="${UPDATED_PACKAGES}\n    - $pkg: $cur → $new"
                OFFICIAL_UPDATED=$((OFFICIAL_UPDATED+1))
                install_lang "$pkg"
            } || {
                log "  ✗ 升级失败"
                FAILED_PACKAGES="${FAILED_PACKAGES}\n    - $pkg"
                OFFICIAL_FAILED=$((OFFICIAL_FAILED+1))
            }
        } || {
            OFFICIAL_SKIPPED=$((OFFICIAL_SKIPPED+1))
        }
    done
    
    log "官方源: 升级 $OFFICIAL_UPDATED, 最新 $OFFICIAL_SKIPPED, 失败 $OFFICIAL_FAILED"
}

# 更新第三方包
update_thirdparty() {
    log "步骤: 更新第三方源"
    
    local check=""
    for pkg in $NON_OFFICIAL_PACKAGES; do
        case "$pkg" in luci-app-*|luci-theme-*|lucky) check="$check $pkg" ;; esac
    done
    
    [ -z "$check" ] && { log "无第三方插件"; return; }
    log "检查 $(echo $check|wc -w) 个第三方插件"
    
    for pkg in $check; do
        local orig="$pkg"
        for saved in $THIRD_PARTY_INSTALLED; do
            [ "$(to_lower "$pkg")" = "$(to_lower "$saved")" ] && orig="$saved" && break
        done
        
        local cur=$(get_version "$pkg" installed)
        log "🔍 $orig (当前: $cur)"
        
        process_package "$orig" 1 "$cur"
        case $? in
            0) THIRDPARTY_UPDATED=$((THIRDPARTY_UPDATED+1)) ;;
            2) THIRDPARTY_SAME=$((THIRDPARTY_SAME+1)) ;;
            *) THIRDPARTY_FAILED=$((THIRDPARTY_FAILED+1)) ;;
        esac
    done
    
    log "第三方源: 更新 $THIRDPARTY_UPDATED, 最新 $THIRDPARTY_SAME, 失败 $THIRDPARTY_FAILED"
}

# 检查脚本更新
check_script_update() {
    log "当前版本: $SCRIPT_VERSION"
    local tmp="/tmp/auto-update-new.sh"
    
    for src in $API_SOURCES; do
        parse_source_config "$src"
        local url=$([ "$platform" = "gitcode" ] && \
            echo "https://raw.gitcode.com/${repo}/raw/${branch}/auto-update.sh" || \
            echo "https://gitee.com/${repo}/raw/${branch}/auto-update.sh")
        
        curl -fsSL -o "$tmp" "$url" 2>/dev/null || continue
        grep -q "run_update" "$tmp" || { rm -f "$tmp"; continue; }
        
        local ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$tmp" | head -1)
        [ -z "$ver" ] && continue
        [ "$SCRIPT_VERSION" = "$ver" ] && { rm -f "$tmp"; return; }
        
        version_greater "$ver" "$SCRIPT_VERSION" && {
            log "↻ 发现新版本: $SCRIPT_VERSION → $ver"
            mv "$tmp" "$(readlink -f "$0")" && chmod +x "$(readlink -f "$0")" && {
                log "✓ 更新成功，重启脚本"
                exec "$(readlink -f "$0")" "$@"
            }
        }
        rm -f "$tmp"
    done
}

# 推送
send_push() {
    [ ! -f "/etc/config/wechatpush" ] && return
    [ "$(uci get wechatpush.config.enable 2>/dev/null)" != "1" ] && return
    
    local token=$(uci get wechatpush.config.pushplus_token 2>/dev/null)
    local api="pushplus" url="http://www.pushplus.plus/send"
    
    [ -z "$token" ] && {
        token=$(uci get wechatpush.config.serverchan_3_key 2>/dev/null)
        api="serverchan3" url="https://sctapi.ftqq.com/${token}.send"
    }
    
    [ -z "$token" ] && {
        token=$(uci get wechatpush.config.serverchan_key 2>/dev/null)
        api="serverchan" url="https://sc.ftqq.com/${token}.send"
    }
    
    [ -z "$token" ] && return
    
    log "发送推送 ($api)"
    
    case "$api" in
        pushplus)
            local c=$(echo "$2" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
            curl -s -X POST "$url" -H "Content-Type: application/json" \
                -d "{\"token\":\"$token\",\"title\":\"$1\",\"content\":\"$c\",\"template\":\"txt\"}" | \
                grep -q '"code":200' && log "✓ 推送成功"
            ;;
        *)
            curl -s -X POST "$url" -d "text=$1" -d "desp=$2" | \
                grep -q '"errno":0\|"code":0' && log "✓ 推送成功"
            ;;
    esac
}

# 生成报告
generate_report() {
    local mode="$1"
    local cron=$(crontab -l 2>/dev/null | grep "auto-update.sh" | grep -v "^#" | head -1)
    local schedule="未设置"
    
    if [ -n "$cron" ]; then
        local h=$(echo "$cron" | awk '{print $2}')
        local m=$(echo "$cron" | awk '{print $1}')
        echo "$h" | grep -q "^\*/" && schedule="每$(echo $h|sed 's#\*/##')小时" || \
        [ "$h" != "*" ] && schedule="每天 $(printf "%02d:%02d" "$h" "${m:-0}")"
    fi
    
    REPORT=""
    
    if [ "$mode" = "install" ]; then
        REPORT="📦 包安装结果\n时间: $(date '+%Y-%m-%d %H:%M:%S')\n设备: $DEVICE_MODEL\n\n"
        REPORT="${REPORT}✓ 成功: $(echo $INSTALLED_LIST|wc -w) 个\n"
        REPORT="${REPORT}✗ 失败: $(echo $FAILED_LIST|wc -w) 个\n\n"
        [ -n "$INSTALLED_LIST" ] && {
            REPORT="${REPORT}已安装:\n"
            for p in $INSTALLED_LIST; do REPORT="${REPORT}  - $p\n"; done
        }
    else
        REPORT="脚本版本: $SCRIPT_VERSION\n时间: $(date '+%Y-%m-%d %H:%M:%S')\n\n"
        REPORT="${REPORT}官方源: ✓$OFFICIAL_UPDATED ○$OFFICIAL_SKIPPED ✗$OFFICIAL_FAILED\n"
        REPORT="${REPORT}第三方: ✓$THIRDPARTY_UPDATED ○$THIRDPARTY_SAME ✗$THIRDPARTY_FAILED\n\n"
        REPORT="${REPORT}⏰ 自动更新: $schedule\n"
    fi
    
    REPORT="${REPORT}\n详细日志: $LOG_FILE"
}

# update 模式
run_update() {
    > "$LOG_FILE"
    log "OpenWrt 自动更新 v$SCRIPT_VERSION"
    
    load_config || return 1
    log "架构: $SYS_ARCH | 包管理: $PKG_TYPE | 策略: $([ "$INSTALL_PRIORITY" = "1" ] && echo 官方优先 || echo 第三方优先)"
    
    check_script_update
    classify_packages || return 1
    
    [ "$INSTALL_PRIORITY" = "1" ] && {
        update_official
        update_thirdparty
    } || {
        update_thirdparty
        update_official
    }
    
    log "✓ 更新完成"
    generate_report "update"
    echo "$REPORT"
    send_push "$PUSH_TITLE" "$REPORT"
}

case "$1" in
    install) shift; run_install "$@" ;;
    *) run_update ;;
esac
