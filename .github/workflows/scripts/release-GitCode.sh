#!/bin/bash

set -e

GITCODE_TOKEN="${GITCODE_TOKEN:-}"
USERNAME="${USERNAME:-whzhni}"
REPO_NAME="${REPO_NAME:-test-release}"
REPO_DESC="${REPO_DESC:-GitCode Release Repository}"
REPO_PRIVATE="${REPO_PRIVATE:-false}"
TAG_NAME="${TAG_NAME:-v1.0.0}"
RELEASE_TITLE="${RELEASE_TITLE:-Release ${TAG_NAME}}"
RELEASE_BODY="${RELEASE_BODY:-Release ${TAG_NAME}}"
BRANCH="${BRANCH:-main}"
UPLOAD_FILES="${UPLOAD_FILES:-}"

API_BASE="https://api.gitcode.com/api/v5"
REPO_PATH="${USERNAME}/${REPO_NAME}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

api_get() {
    local endpoint="$1"
    curl -s -H "PRIVATE-TOKEN: ${GITCODE_TOKEN}" "${API_BASE}${endpoint}"
}

api_post() {
    local endpoint="$1"
    local data="$2"
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "PRIVATE-TOKEN: ${GITCODE_TOKEN}" \
        -d "$data" \
        "${API_BASE}${endpoint}"
}

api_put() {
    local endpoint="$1"
    local data="$2"
    curl -s -X PUT \
        -H "Content-Type: application/json" \
        -H "PRIVATE-TOKEN: ${GITCODE_TOKEN}" \
        -d "$data" \
        "${API_BASE}${endpoint}"
}

api_delete() {
    local endpoint="$1"
    curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "PRIVATE-TOKEN: ${GITCODE_TOKEN}" \
        "${API_BASE}${endpoint}"
}

upload_file_to_repo() {
    local file="$1"
    local filename=$(basename "$file")
    local file_path="releases/${TAG_NAME}/${filename}"
    
    log_info "上传: $filename ($(du -h "$file" | cut -f1))"
    
    local file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    local file_size_mb=$((file_size / 1024 / 1024))
    
    if [ $file_size_mb -gt 100 ]; then
        log_error "文件过大: $file_size_mb MB"
        return 1
    fi
    
    local content_base64=$(base64 -w 0 "$file" 2>/dev/null || base64 "$file")
    
    local existing=$(api_get "/repos/${REPO_PATH}/contents/${file_path}" 2>/dev/null || echo "")
    
    local response=""
    if echo "$existing" | grep -q '"sha"'; then
        local sha=""
        if command -v jq &>/dev/null; then
            sha=$(echo "$existing" | jq -r '.sha // empty')
        else
            sha=$(echo "$existing" | grep -o '"sha":"[^"]*"' | head -1 | cut -d'"' -f4)
        fi
        
        response=$(api_put "/repos/${REPO_PATH}/contents/${file_path}" "{
            \"message\":\"Update ${filename} for ${TAG_NAME}\",
            \"content\":\"${content_base64}\",
            \"sha\":\"${sha}\",
            \"branch\":\"${BRANCH}\"
        }")
    else
        response=$(api_post "/repos/${REPO_PATH}/contents/${file_path}" "{
            \"message\":\"Add ${filename} for ${TAG_NAME}\",
            \"content\":\"${content_base64}\",
            \"branch\":\"${BRANCH}\"
        }")
    fi
    
    if echo "$response" | grep -q '"sha"'; then
        log_success "上传成功"
        echo "https://gitcode.com/${REPO_PATH}/raw/${BRANCH}/${file_path}"
        return 0
    else
        log_error "上传失败"
        return 1
    fi
}

check_token() {
    echo ""
    log_info "检查环境配置"
    
    if [ -z "$GITCODE_TOKEN" ]; then
        log_error "GITCODE_TOKEN 未设置"
        exit 1
    fi
    
    log_success "Token 已配置"
}

ensure_repository() {
    echo ""
    log_info "步骤 1/5: 检查仓库"
    
    local response=$(api_get "/repos/${REPO_PATH}")
    
    if echo "$response" | grep -q '"id"'; then
        log_success "仓库已存在"
        return 0
    fi
    
    log_warning "仓库不存在，创建中..."
    
    local private_val="false"
    [ "$REPO_PRIVATE" = "true" ] && private_val="true"
    
    response=$(api_post "/user/repos" "{
        \"name\":\"${REPO_NAME}\",
        \"description\":\"${REPO_DESC}\",
        \"private\":${private_val},
        \"has_issues\":true,
        \"has_wiki\":true,
        \"auto_init\":false
    }")
    
    if echo "$response" | grep -q '"id"'; then
        log_success "仓库创建成功"
        sleep 5
    else
        log_error "仓库创建失败"
        exit 1
    fi
}

ensure_branch() {
    echo ""
    log_info "步骤 2/5: 检查分支"
    
    local response=$(api_get "/repos/${REPO_PATH}/branches/${BRANCH}")
    
    if echo "$response" | grep -q '"name"'; then
        log_success "分支已存在"
        return 0
    fi
    
    log_warning "分支不存在，创建中..."
    
    [ -f ".git/shallow" ] && { git fetch --unshallow || { rm -rf .git; git init; }; }
    [ ! -d ".git" ] && git init
    
    git config user.name "GitCode Bot"
    git config user.email "bot@gitcode.com"
    
    [ ! -f "README.md" ] && echo -e "# ${REPO_NAME}\n\n${REPO_DESC}" > README.md
    
    git add -A
    git diff --cached --quiet && git commit --allow-empty -m "Initial commit" || git commit -m "Initial commit"
    
    local git_url="https://oauth2:${GITCODE_TOKEN}@gitcode.com/${REPO_PATH}.git"
    git remote get-url gitcode &>/dev/null && git remote set-url gitcode "$git_url" || git remote add gitcode "$git_url"
    
    git push gitcode HEAD:refs/heads/${BRANCH} 2>&1 | sed "s/${GITCODE_TOKEN}/***TOKEN***/g" || {
        log_error "推送失败"
        exit 1
    }
    
    log_success "分支创建成功"
    sleep 3
}

cleanup_old_tags() {
    echo ""
    log_info "步骤 3/5: 清理旧标签"
    
    local response=$(api_get "/repos/${REPO_PATH}/tags")
    
    if ! echo "$response" | grep -q '\['; then
        log_info "没有旧标签"
        return 0
    fi
    
    local tags=""
    if command -v jq &>/dev/null; then
        tags=$(echo "$response" | jq -r '.[].name' 2>/dev/null)
    else
        tags=$(echo "$response" | grep -o '{"name":"[^"]*"' | cut -d'"' -f4)
    fi
    
    if [ -z "$tags" ]; then
        log_info "没有旧标签"
        return 0
    fi
    
    local deleted=0
    while IFS= read -r tag; do
        [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
        
        if ! echo "$tag" | grep -qE '^(v[0-9]|[0-9])'; then
            continue
        fi
        
        log_warning "删除: $tag"
        
        local http_code=$(api_delete "/repos/${REPO_PATH}/tags/${tag}")
        
        if [ "$http_code" -eq 204 ] || [ "$http_code" -eq 200 ]; then
            deleted=$((deleted + 1))
        fi
        
        sleep 1
    done <<< "$tags"
    
    [ $deleted -gt 0 ] && log_info "已删除 $deleted 个旧标签" || log_info "没有需要删除的标签"
}

upload_files() {
    echo ""
    log_info "步骤 4/5: 上传文件到仓库"
    
    if [ -z "$UPLOAD_FILES" ]; then
        log_info "没有文件需要上传"
        return 0
    fi
    
    local uploaded=0
    local failed=0
    FILE_LINKS=""
    
    IFS=' ' read -ra FILES <<< "$UPLOAD_FILES"
    local total=${#FILES[@]}
    
    for file in "${FILES[@]}"; do
        [ -z "$file" ] && continue
        
        if [ ! -f "$file" ]; then
            log_warning "文件不存在: $file"
            failed=$((failed + 1))
            continue
        fi
        
        local filename=$(basename "$file")
        echo ""
        log_info "[$(( uploaded + failed + 1 ))/${total}] $filename"
        
        if download_url=$(upload_file_to_repo "$file"); then
            uploaded=$((uploaded + 1))
            FILE_LINKS="${FILE_LINKS}- [📦 ${filename}](${download_url})
"
        else
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    log_success "上传完成: $uploaded 成功, $failed 失败"
}

create_release() {
    echo ""
    log_info "步骤 5/5: 创建 Release"
    log_info "标签: ${TAG_NAME}"
    log_info "标题: ${RELEASE_TITLE}"
    
    # 构建完整的 Release 描述（包含文件链接）
    local full_body="${RELEASE_BODY}"
    
    if [ -n "$FILE_LINKS" ]; then
        full_body="${full_body}

## 📥 下载文件

${FILE_LINKS}
> 💡 **提示**: 点击文件名即可下载"
    fi
    
    # 转义为 JSON
    local body_json=$(echo "$full_body" | jq -Rs .)
    
    # 先尝试删除已存在的 Release
    api_delete "/repos/${REPO_PATH}/releases/tags/${TAG_NAME}" >/dev/null 2>&1 || true
    
    # 创建新的 Release
    local response=$(api_post "/repos/${REPO_PATH}/releases" "{
        \"tag_name\":\"${TAG_NAME}\",
        \"name\":\"${RELEASE_TITLE}\",
        \"body\":${body_json},
        \"target_commitish\":\"${BRANCH}\"
    }")
    
    if echo "$response" | grep -q "\"tag_name\":\"${TAG_NAME}\""; then
        log_success "Release 创建成功"
    else
        log_error "创建失败"
        log_debug "响应: ${response:0:300}"
        exit 1
    fi
}

verify_release() {
    echo ""
    log_info "验证 Release"
    
    local response=$(api_get "/repos/${REPO_PATH}/releases/tags/${TAG_NAME}")
    
    if echo "$response" | grep -q "\"tag_name\":\"${TAG_NAME}\""; then
        log_success "验证成功"
    else
        log_error "验证失败"
        exit 1
    fi
}

main() {
    echo ""
    echo "═══════════════════════════════════════"
    echo "  GitCode Release 发布脚本"
    echo "═══════════════════════════════════════"
    echo ""
    echo "仓库: ${REPO_PATH}"
    echo "标签: ${TAG_NAME}"
    echo ""
    
    check_token
    ensure_repository
    ensure_branch
    cleanup_old_tags
    upload_files          # 先上传文件
    create_release        # 再创建 Release（包含文件链接）
    verify_release
    
    echo ""
    echo "═══════════════════════════════════════"
    log_success "🎉 发布完成"
    echo "═══════════════════════════════════════"
    echo ""
    echo "Release 地址:"
    echo "  https://gitcode.com/${REPO_PATH}/releases"
    echo ""
    echo "文件目录:"
    echo "  https://gitcode.com/${REPO_PATH}/tree/${BRANCH}/releases/${TAG_NAME}"
    echo ""
}

main "$@"
