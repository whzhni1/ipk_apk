#!/bin/bash

set -e

# 配置（通过环境变量传入）
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

# API 配置
API_BASE="https://gitcode.com/api/v5"
REPO_PATH="${USERNAME}/${REPO_NAME}"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

# API v5 使用 access_token query 参数
api_get() {
    local endpoint="$1"
    curl -s "${API_BASE}${endpoint}?access_token=${GITCODE_TOKEN}"
}

api_post() {
    local endpoint="$1"
    local data="$2"
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$data" \
        "${API_BASE}${endpoint}?access_token=${GITCODE_TOKEN}"
}

api_patch() {
    local endpoint="$1"
    local data="$2"
    curl -s -X PATCH \
        -H "Content-Type: application/json" \
        -d "$data" \
        "${API_BASE}${endpoint}?access_token=${GITCODE_TOKEN}"
}

api_delete() {
    local endpoint="$1"
    curl -s -X DELETE "${API_BASE}${endpoint}?access_token=${GITCODE_TOKEN}"
}

api_upload() {
    local file="$1"
    local release_id="$2"
    curl -s -X POST \
        -F "file=@${file}" \
        "${API_BASE}/repos/${REPO_PATH}/releases/${release_id}/attach_files?access_token=${GITCODE_TOKEN}"
}

check_token() {
    echo ""
    log_info "检查环境配置"
    
    if [ -z "$GITCODE_TOKEN" ]; then
        log_error "GITCODE_TOKEN 未设置"
        echo "请设置: export GITCODE_TOKEN='your_token'"
        exit 1
    fi
    
    log_success "Token 已配置"
}

ensure_repository() {
    echo ""
    log_info "步骤 1/6: 检查仓库 ${REPO_PATH}"
    
    response=$(api_get "/repos/${REPO_PATH}")
    
    if echo "$response" | grep -q '"id"'; then
        log_success "仓库已存在"
        return 0
    fi
    
    log_warning "仓库不存在，创建中..."
    
    private_val="false"
    [ "$REPO_PRIVATE" = "true" ] && private_val="true"
    
    response=$(api_post "/user/repos" "{
        \"name\": \"${REPO_NAME}\",
        \"description\": \"${REPO_DESC}\",
        \"private\": ${private_val},
        \"has_issues\": true,
        \"has_wiki\": true,
        \"auto_init\": false
    }")
    
    if echo "$response" | grep -q '"id"'; then
        log_success "仓库创建成功"
        sleep 5
    else
        log_error "仓库创建失败"
        echo "$response"
        exit 1
    fi
}

ensure_branch() {
    echo ""
    log_info "步骤 2/6: 检查分支 ${BRANCH}"
    
    response=$(api_get "/repos/${REPO_PATH}/branches/${BRANCH}")
    
    if echo "$response" | grep -q '"name"'; then
        log_success "分支已存在"
        return 0
    fi
    
    log_warning "分支不存在，创建中..."
    
    [ ! -d ".git" ] && git init
    
    git config user.name "GitCode Bot"
    git config user.email "bot@gitcode.com"
    
    if [ ! -f "README.md" ]; then
        echo "# ${REPO_NAME}" > README.md
        echo "" >> README.md
        echo "${REPO_DESC}" >> README.md
    fi
    
    git add -A
    git diff --cached --quiet && git commit --allow-empty -m "Initial commit" || git commit -m "Initial commit"
    
    if git remote get-url gitcode &>/dev/null; then
        git remote set-url gitcode "https://${GITCODE_TOKEN}@gitcode.com/${REPO_PATH}.git"
    else
        git remote add gitcode "https://${GITCODE_TOKEN}@gitcode.com/${REPO_PATH}.git"
    fi
    
    git push gitcode HEAD:refs/heads/${BRANCH} 2>&1 | grep -v "${GITCODE_TOKEN}"
    
    log_success "分支创建成功"
    sleep 3
}

cleanup_old_tags() {
    echo ""
    log_info "步骤 3/6: 清理旧标签"
    
    response=$(api_get "/repos/${REPO_PATH}/tags")
    
    tags=$(echo "$response" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$tags" ]; then
        log_info "没有现有标签"
        return 0
    fi
    
    deleted=0
    while IFS= read -r tag; do
        [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
        
        log_warning "删除标签: $tag"
        
        # 获取 release id
        rel_response=$(api_get "/repos/${REPO_PATH}/releases/tags/${tag}")
        rel_id=$(echo "$rel_response" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        
        # 删除 release
        [ -n "$rel_id" ] && api_delete "/repos/${REPO_PATH}/releases/${rel_id}" &>/dev/null
        
        # 删除标签
        api_delete "/repos/${REPO_PATH}/tags/${tag}" &>/dev/null
        
        deleted=$((deleted + 1))
        sleep 1
    done <<< "$tags"
    
    [ $deleted -gt 0 ] && log_success "删除了 ${deleted} 个旧标签" || log_info "无需删除"
}

create_release() {
    echo ""
    log_info "步骤 4/6: 创建 Release"
    log_info "标签: ${TAG_NAME}"
    log_info "标题: ${RELEASE_TITLE}"
    
    response=$(api_post "/repos/${REPO_PATH}/releases" "{
        \"tag_name\": \"${TAG_NAME}\",
        \"name\": \"${RELEASE_TITLE}\",
        \"body\": \"${RELEASE_BODY}\",
        \"target_commitish\": \"${BRANCH}\"
    }")
    
    if echo "$response" | grep -q '"id"'; then
        RELEASE_ID=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        log_success "Release 创建成功 (ID: ${RELEASE_ID})"
        return 0
    else
        log_error "Release 创建失败"
        echo "$response"
        exit 1
    fi
}

upload_files() {
    echo ""
    log_info "步骤 5/6: 上传文件"
    
    if [ -z "$UPLOAD_FILES" ]; then
        log_info "没有文件需要上传"
        return 0
    fi
    
    uploaded=0
    failed=0
    
    IFS=' ' read -ra FILES <<< "$UPLOAD_FILES"
    total=${#FILES[@]}
    
    for file in "${FILES[@]}"; do
        [ -z "$file" ] && continue
        
        if [ ! -f "$file" ]; then
            log_warning "文件不存在: $file"
            failed=$((failed + 1))
            continue
        fi
        
        size=$(du -h "$file" | cut -f1)
        log_info "[$(( uploaded + failed + 1 ))/${total}] $file ($size)"
        
        response=$(api_upload "$file" "$RELEASE_ID")
        
        if echo "$response" | grep -q '"name"'; then
            log_success "上传成功"
            uploaded=$((uploaded + 1))
        else
            log_error "上传失败"
            failed=$((failed + 1))
        fi
    done
    
    log_success "上传完成: ${uploaded} 成功, ${failed} 失败"
}

verify_release() {
    echo ""
    log_info "步骤 6/6: 验证 Release"
    
    response=$(api_get "/repos/${REPO_PATH}/releases/tags/${TAG_NAME}")
    
    if echo "$response" | grep -q '"tag_name"'; then
        log_success "验证成功"
        log_info "地址: https://gitcode.com/${REPO_PATH}/releases/tag/${TAG_NAME}"
    else
        log_error "验证失败"
        exit 1
    fi
}

main() {
    echo ""
    echo "GitCode Release 发布脚本"
    echo ""
    echo "仓库: ${REPO_PATH}"
    echo "标签: ${TAG_NAME}"
    echo "分支: ${BRANCH}"
    
    check_token
    ensure_repository
    ensure_branch
    cleanup_old_tags
    create_release
    upload_files
    verify_release
    
    echo ""
    log_success "🎉 发布完成"
    echo ""
    echo "访问: https://gitcode.com/${REPO_PATH}/releases/tag/${TAG_NAME}"
    echo ""
}

main "$@"
