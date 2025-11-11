#!/bin/bash

set -e

# ==================== 环境变量配置 ====================
GITEE_TOKEN="${GITEE_TOKEN:-}"
USERNAME="${USERNAME:-}"
REPO_NAME="${REPO_NAME:-}"
REPO_DESC="${REPO_DESC:-Gitee Release Repository}"
REPO_PRIVATE="${REPO_PRIVATE:-false}"
TAG_NAME="${TAG_NAME:-v1.0.0}"
RELEASE_TITLE="${RELEASE_TITLE:-Release ${TAG_NAME}}"
RELEASE_BODY="${RELEASE_BODY:-Release ${TAG_NAME}}"
BRANCH="${BRANCH:-master}"
UPLOAD_FILES="${UPLOAD_FILES:-}"

API_BASE="https://gitee.com/api/v5"
REPO_PATH="${USERNAME}/${REPO_NAME}"

# ==================== 颜色定义 ====================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 日志函数 ====================
log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

# ==================== API 函数封装 ====================
api_get() {
    local endpoint="$1"
    curl -s "${API_BASE}${endpoint}?access_token=${GITEE_TOKEN}"
}

api_post() {
    local endpoint="$1"
    local data="$2"
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$data" \
        "${API_BASE}${endpoint}?access_token=${GITEE_TOKEN}"
}

api_delete() {
    local endpoint="$1"
    curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "${API_BASE}${endpoint}?access_token=${GITEE_TOKEN}"
}

# ==================== 文件上传函数（保留原有逻辑）====================
upload_file_to_release() {
    local file="$1"
    local release_id="$2"
    local filename=$(basename "$file")
    
    log_info "上传: $filename ($(du -h "$file" | cut -f1))"
    
    # 使用 Gitee 的上传接口
    local upload_response=$(curl -s -X POST \
        "$API_BASE/repos/$REPO_PATH/releases/$release_id/attach_files" \
        -F "access_token=$GITEE_TOKEN" \
        -F "file=@$file")
    
    # 检查上传结果
    if echo "$upload_response" | jq -e '.browser_download_url' > /dev/null 2>&1; then
        log_success "上传成功"
        return 0
    else
        local error_msg=$(echo "$upload_response" | jq -r '.message // "未知错误"')
        log_error "上传失败: $error_msg"
        return 1
    fi
}

# ==================== 核心功能函数 ====================
check_token() {
    echo ""
    log_info "检查环境配置"
    
    if [ -z "$GITEE_TOKEN" ]; then
        log_error "GITEE_TOKEN 未设置"
        exit 1
    fi
    
    if [ -z "$USERNAME" ] || [ -z "$REPO_NAME" ]; then
        log_error "USERNAME 或 REPO_NAME 未设置"
        exit 1
    fi
    
    log_success "Token 已配置"
}

ensure_repository() {
    echo ""
    log_info "步骤 1/5: 检查仓库"
    
    local response=$(api_get "/repos/${REPO_PATH}")
    
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
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
    
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        log_success "仓库创建成功"
        sleep 5
    else
        log_error "仓库创建失败"
        log_debug "响应: $response"
        exit 1
    fi
}

ensure_branch() {
    echo ""
    log_info "步骤 2/5: 检查分支"
    
    local response=$(api_get "/repos/${REPO_PATH}/branches/${BRANCH}")
    
    if echo "$response" | jq -e '.name' > /dev/null 2>&1; then
        log_success "分支已存在"
        return 0
    fi
    
    log_warning "分支不存在，创建中..."
    
    [ -f ".git/shallow" ] && { git fetch --unshallow || { rm -rf .git; git init; }; }
    [ ! -d ".git" ] && git init
    
    git config user.name "Gitee Bot"
    git config user.email "bot@gitee.com"
    
    [ ! -f "README.md" ] && echo -e "# ${REPO_NAME}\n\n${REPO_DESC}" > README.md
    
    git add -A
    git diff --cached --quiet && git commit --allow-empty -m "Initial commit" || git commit -m "Initial commit"
    
    local git_url="https://oauth2:${GITEE_TOKEN}@gitee.com/${REPO_PATH}.git"
    git remote get-url gitee &>/dev/null && git remote set-url gitee "$git_url" || git remote add gitee "$git_url"
    
    git push gitee HEAD:refs/heads/${BRANCH} 2>&1 | sed "s/${GITEE_TOKEN}/***TOKEN***/g" || {
        log_error "推送失败"
        exit 1
    }
    
    log_success "分支创建成功"
    sleep 3
}

cleanup_old_tags() {
    echo ""
    log_info "步骤 3/5: 清理旧标签"
    
    # 获取所有 Release
    local releases=$(api_get "/repos/${REPO_PATH}/releases")
    
    if ! echo "$releases" | jq -e '.[0]' > /dev/null 2>&1; then
        log_info "没有旧 Release"
    else
        log_debug "检查旧 Release..."
        
        local release_tags=$(echo "$releases" | jq -r '.[].tag_name' 2>/dev/null)
        local deleted_releases=0
        
        while IFS= read -r tag; do
            [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
            
            if ! echo "$tag" | grep -qE '^(v[0-9]|[0-9])'; then
                continue
            fi
            
            log_warning "删除 Release: $tag"
            
            # 获取 Release ID
            local release_id=$(echo "$releases" | jq -r --arg tag "$tag" '.[] | select(.tag_name == $tag) | .id')
            
            if [ -n "$release_id" ] && [ "$release_id" != "null" ]; then
                local http_code=$(api_delete "/repos/${REPO_PATH}/releases/${release_id}")
                
                if [ "$http_code" -eq 204 ] || [ "$http_code" -eq 200 ]; then
                    log_debug "  ✓ Release 已删除"
                    deleted_releases=$((deleted_releases + 1))
                    sleep 1
                else
                    log_debug "  ! Release 删除失败 (HTTP $http_code)"
                fi
            fi
        done <<< "$release_tags"
        
        [ $deleted_releases -gt 0 ] && log_info "已删除 $deleted_releases 个 Release"
    fi
    
    # 获取所有 Tag
    local tags_response=$(api_get "/repos/${REPO_PATH}/tags")
    
    if ! echo "$tags_response" | jq -e '.[0]' > /dev/null 2>&1; then
        log_info "没有旧标签"
        return 0
    fi
    
    local tags=$(echo "$tags_response" | jq -r '.[].name' 2>/dev/null)
    
    if [ -z "$tags" ]; then
        log_info "没有旧标签"
        return 0
    fi
    
    local deleted_tags=0
    
    while IFS= read -r tag; do
        [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
        
        if ! echo "$tag" | grep -qE '^(v[0-9]|[0-9])'; then
            continue
        fi
        
        log_warning "删除 Tag: $tag"
        
        # Gitee 删除 Tag 的 API
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            "${API_BASE}/repos/${REPO_PATH}/tags/${tag}?access_token=${GITEE_TOKEN}")
        
        log_debug "  HTTP $http_code"
        
        if [ "$http_code" -eq 204 ] || [ "$http_code" -eq 200 ] || [ "$http_code" -eq 404 ]; then
            deleted_tags=$((deleted_tags + 1))
            log_debug "  ✓ Tag 已删除"
        else
            log_debug "  ! Tag 删除失败"
        fi
        
        sleep 1
    done <<< "$tags"
    
    if [ $deleted_tags -gt 0 ]; then
        log_success "已删除 $deleted_tags 个标签"
    else
        log_info "没有标签被删除"
    fi
}

create_release() {
    echo ""
    log_info "步骤 4/5: 创建 Release"
    log_info "标签: ${TAG_NAME}"
    log_info "标题: ${RELEASE_TITLE}"
    
    # 检查 Release 是否已存在
    local releases=$(api_get "/repos/${REPO_PATH}/releases")
    local existing_release=$(echo "$releases" | jq -r --arg tag "$TAG_NAME" '.[] | select(.tag_name == $tag)')
    
    if [ -n "$existing_release" ]; then
        RELEASE_ID=$(echo "$existing_release" | jq -r '.id // empty')
        
        if [ -n "$RELEASE_ID" ] && [ "$RELEASE_ID" != "null" ]; then
            log_warning "Release 已存在，使用 ID: $RELEASE_ID"
            return 0
        fi
    fi
    
    # 获取最新 commit
    log_debug "获取最新 commit..."
    local commit_info=$(api_get "/repos/${REPO_PATH}/commits")
    local latest_commit=$(echo "$commit_info" | jq -r '.[0].sha // empty')
    
    if [ -z "$latest_commit" ] || [ "$latest_commit" = "null" ]; then
        log_error "无法获取最新 commit"
        exit 1
    fi
    
    log_debug "commit: ${latest_commit:0:8}..."
    
    # 创建 Release
    local release_payload=$(jq -n \
        --arg tag "$TAG_NAME" \
        --arg name "$RELEASE_TITLE" \
        --arg body "$RELEASE_BODY" \
        --arg ref "$latest_commit" \
        '{
            tag_name: $tag,
            name: $name,
            body: $body,
            target_commitish: $ref,
            prerelease: false
        }')
    
    local release_response=$(echo "$release_payload" | curl -s -X POST \
        "${API_BASE}/repos/${REPO_PATH}/releases?access_token=${GITEE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @-)
    
    RELEASE_ID=$(echo "$release_response" | jq -r '.id // empty')
    
    if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" = "null" ]; then
        log_error "创建 Release 失败"
        log_debug "响应: $release_response"
        exit 1
    fi
    
    log_success "Release 创建成功，ID: $RELEASE_ID"
}

upload_files() {
    echo ""
    log_info "步骤 5/5: 上传文件到 Release"
    
    if [ -z "$UPLOAD_FILES" ]; then
        log_info "没有文件需要上传"
        return 0
    fi
    
    if [ -z "$RELEASE_ID" ]; then
        log_error "RELEASE_ID 未设置"
        exit 1
    fi
    
    local uploaded=0
    local failed=0
    
    IFS=' ' read -ra FILES <<< "$UPLOAD_FILES"
    local total=${#FILES[@]}
    
    for file in "${FILES[@]}"; do
        [ -z "$file" ] && continue
        
        if [ ! -f "$file" ]; then
            log_warning "文件不存在: $file"
            failed=$((failed + 1))
            continue
        fi
        
        echo ""
        log_info "[$(( uploaded + failed + 1 ))/${total}] $(basename "$file")"
        
        if upload_file_to_release "$file" "$RELEASE_ID"; then
            uploaded=$((uploaded + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    
    if [ $uploaded -eq $total ]; then
        log_success "全部上传成功: $uploaded/$total"
    elif [ $uploaded -gt 0 ]; then
        log_warning "部分上传成功: $uploaded/$total"
    else
        log_error "全部上传失败"
    fi
}

verify_release() {
    echo ""
    log_info "验证 Release"
    
    local response=$(api_get "/repos/${REPO_PATH}/releases/tags/${TAG_NAME}")
    
    if echo "$response" | jq -e '.tag_name' > /dev/null 2>&1; then
        log_success "验证成功"
        
        local assets=$(echo "$response" | jq '.assets | length')
        log_info "附件数量: $assets"
    else
        log_error "验证失败"
        exit 1
    fi
}

# ==================== 主函数 ====================
main() {
    echo ""
    echo "═══════════════════════════════════════"
    echo "  Gitee Release 发布脚本"
    echo "═══════════════════════════════════════"
    echo ""
    echo "仓库: ${REPO_PATH}"
    echo "标签: ${TAG_NAME}"
    echo ""
    
    check_token
    ensure_repository
    ensure_branch
    cleanup_old_tags
    create_release
    upload_files
    verify_release
    
    echo ""
    echo "═══════════════════════════════════════"
    log_success "🎉 发布完成"
    echo "═══════════════════════════════════════"
    echo ""
    echo "Release 地址:"
    echo "  https://gitee.com/${REPO_PATH}/releases/tag/${TAG_NAME}"
    echo ""
}

main "$@"
