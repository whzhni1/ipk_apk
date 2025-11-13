#!/bin/bash

set -e

#  环境变量配置 
GITEE_TOKEN="${GITEE_TOKEN:-}"
USERNAME="${USERNAME:-}"
REPO_NAME="${REPO_NAME:-}"
REPO_DESC="${REPO_DESC:-Gitee Release Repository}"
REPO_PRIVATE="${REPO_PRIVATE:-false}"
TAG_NAME="${TAG_NAME:-v1.0.0}"
RELEASE_TITLE="${RELEASE_TITLE:-Release ${TAG_NAME}}"
RELEASE_BODY="${RELEASE_BODY:-Release ${TAG_NAME}}"
BRANCH="${BRANCH:-main}"
UPLOAD_FILES="${UPLOAD_FILES:-}"

API_BASE="https://gitee.com/api/v5"
REPO_PATH="${USERNAME}/${REPO_NAME}"
PLATFORM_TAG="[Gitee]"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${CYAN}${PLATFORM_TAG}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}${PLATFORM_TAG}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}${PLATFORM_TAG}[!]${NC} $*"; }
log_error() { echo -e "${RED}${PLATFORM_TAG}[✗]${NC} $*"; }
log_debug() { echo -e "${BLUE}${PLATFORM_TAG}[DEBUG]${NC} $*"; }

#  API 函数封装 
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

#  创建初始文件 
create_initial_file() {
    log_info "创建初始文件..."
    
    # README 内容
    local readme_content="# ${REPO_NAME}

${REPO_DESC}

## 📦 Release

本仓库用于自动发布构建产物。

## 🔗 链接

- Gitee: https://gitee.com/${REPO_PATH}
"
    
    # Base64 编码
    local encoded_content=$(echo -n "$readme_content" | base64 | tr -d '\n')
    
    # 创建文件的 JSON payload
    local create_payload=$(jq -n \
        --arg message "Initial commit" \
        --arg content "$encoded_content" \
        --arg branch "$BRANCH" \
        '{
            message: $message,
            content: $content,
            branch: $branch
        }')
    
    # 使用 API 创建文件
    local response=$(echo "$create_payload" | curl -s -X POST \
        "${API_BASE}/repos/${REPO_PATH}/contents/README.md?access_token=${GITEE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @-)
    
    # 检查是否成功
    if echo "$response" | jq -e '.content.sha' > /dev/null 2>&1; then
        log_success "初始文件创建成功"
        return 0
    else
        log_warning "初始文件创建失败，尝试 Git 方式..."
        return 1
    fi
}

#  使用 Git 创建初始提交 
create_initial_commit_with_git() {
    log_debug "使用 Git 创建初始提交..."
    
    # 使用独立的临时目录
    local temp_dir="${RUNNER_TEMP:-/tmp}/gitee-init-$$-${RANDOM}"
    mkdir -p "$temp_dir"
    
    local current_dir=$(pwd)
    cd "$temp_dir"
    
    git init -q
    git config user.name "Gitee Bot"
    git config user.email "bot@gitee.com"
    
    cat > README.md << EOF
# ${REPO_NAME}

${REPO_DESC}

## 📦 Release

本仓库用于自动发布构建产物。
EOF
    
    git add README.md
    git commit -m "Initial commit" -q
    
    local git_url="https://oauth2:${GITEE_TOKEN}@gitee.com/${REPO_PATH}.git"
    git remote add origin "$git_url"
    
    if git push -u origin master 2>&1 | sed "s/${GITEE_TOKEN}/***TOKEN***/g"; then
        log_success "初始提交成功"
        cd "$current_dir"
        rm -rf "$temp_dir"
        return 0
    else
        log_error "初始提交失败"
        cd "$current_dir"
        rm -rf "$temp_dir"
        return 1
    fi
}

#  文件上传函数 
upload_file_to_release() {
    local file="$1"
    local release_id="$2"
    local filename=$(basename "$file")
    
    log_info "上传: $filename ($(du -h "$file" | cut -f1))"
    
    local upload_response=$(curl -s -X POST \
        "$API_BASE/repos/$REPO_PATH/releases/$release_id/attach_files" \
        -F "access_token=$GITEE_TOKEN" \
        -F "file=@$file")
    
    if echo "$upload_response" | jq -e '.browser_download_url' > /dev/null 2>&1; then
        log_success "上传成功"
        return 0
    else
        local error_msg=$(echo "$upload_response" | jq -r '.message // "未知错误"')
        log_error "上传失败: $error_msg"
        return 1
    fi
}

#  核心功能函数 
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
    log_info "步骤 1/4: 检查仓库"

    local response=$(api_get "/repos/${REPO_PATH}")

    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        log_success "仓库已存在"
        return 0
    fi

    log_warning "仓库不存在，创建中..."

    # 创建仓库（默认私有）
    response=$(api_post "/user/repos" "{
        \"access_token\": \"${GITEE_TOKEN}\",
        \"name\": \"${REPO_NAME}\",
        \"description\": \"${REPO_DESC}\",
        \"has_issues\": true,
        \"has_wiki\": true,
        \"auto_init\": false
    }")

    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        log_success "仓库创建成功 (默认私有)"
        sleep 3

        # 初始化仓库
        log_info "初始化仓库到分支: ${BRANCH}"

        local temp_dir="${RUNNER_TEMP:-/tmp}/gitee-init-$$-${RANDOM}"
        mkdir -p "$temp_dir"

        local current_dir=$(pwd)
        cd "$temp_dir"

        git init -q
        git config user.name "Gitee Bot"
        git config user.email "bot@gitee.com"

        cat > README.md << EOF
# ${REPO_NAME}

${REPO_DESC}

## 📦 Release

本仓库用于自动发布构建产物。
EOF

        git add README.md
        git commit -m "Initial commit" -q

        local git_url="https://oauth2:${GITEE_TOKEN}@gitee.com/${REPO_PATH}.git"
        git remote add origin "$git_url"

        if git push -u origin HEAD:"${BRANCH}" 2>&1 | sed "s/${GITEE_TOKEN}/***TOKEN***/g"; then
            log_success "仓库初始化完成 (分支: ${BRANCH})"
        else
            log_error "初始化失败"
            cd "$current_dir"
            rm -rf "$temp_dir"
            exit 1
        fi

        cd "$current_dir"
        rm -rf "$temp_dir"

    else
        log_error "仓库创建失败"
        log_debug "响应: $response"
        exit 1
    fi
}

cleanup_old_tags() {
    echo ""
    log_info "步骤 2/4: 清理旧标签和 Release"
    
    if ! command -v git &> /dev/null; then
        log_warning "未找到 git 命令，跳过标签清理"
        return 0
    fi
    
    local deleted_count=0
    
    # 使用独立的临时目录
    local temp_git_dir="${RUNNER_TEMP:-/tmp}/gitee-cleanup-$$-${RANDOM}"
    mkdir -p "$temp_git_dir"
    local current_dir=$(pwd)
    
    cd "$temp_git_dir"
    git init -q
    git config user.name "Gitee Bot"
    git config user.email "bot@gitee.com"
    
    local git_url="https://oauth2:${GITEE_TOKEN}@gitee.com/${REPO_PATH}.git"
    git remote add origin "$git_url"
    
    # 获取所有标签
    log_debug "获取标签列表..."
    local tags_response=$(api_get "/repos/${REPO_PATH}/tags")
    
    if ! echo "$tags_response" | jq -e '.[0]' > /dev/null 2>&1; then
        log_info "没有旧标签"
        cd "$current_dir"
        rm -rf "$temp_git_dir"
        return 0
    fi
    
    local tags=$(echo "$tags_response" | jq -r '.[].name' 2>/dev/null)
    
    if [ -z "$tags" ]; then
        log_info "没有旧标签"
        cd "$current_dir"
        rm -rf "$temp_git_dir"
        return 0
    fi
    
    # 遍历删除
    while IFS= read -r tag; do
        [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
        
        if ! echo "$tag" | grep -qE '^(v[0-9]|[0-9])'; then
            continue
        fi
        
        echo ""
        log_warning "清理: $tag"
        
        # 1. 删除 Release
        local release=$(api_get "/repos/${REPO_PATH}/releases/tags/${tag}")
        local release_id=$(echo "$release" | jq -r '.id // empty')
        
        if [ -n "$release_id" ] && [ "$release_id" != "null" ]; then
            log_debug "  删除 Release (ID: $release_id)..."
            api_delete "/repos/${REPO_PATH}/releases/${release_id}" >/dev/null 2>&1
            sleep 1
        fi
        
        # 2. 删除 Git 标签
        log_debug "  删除 Git 标签..."
        
        local output=$(git push origin ":refs/tags/${tag}" 2>&1 | sed "s/${GITEE_TOKEN}/***TOKEN***/g")
        
        if [ $? -eq 0 ]; then
            log_success "  ✓ 已删除"
            deleted_count=$((deleted_count + 1))
        else
            if echo "$output" | grep -qiE "not found|does not exist|couldn't find"; then
                log_debug "  ✓ 不存在（已删除）"
            else
                log_error "  ✗ 删除失败"
                log_debug "  $(echo "$output" | head -1)"
            fi
        fi
        
        sleep 1
    done <<< "$tags"
    
    # 返回原目录并清理
    cd "$current_dir"
    rm -rf "$temp_git_dir"
    
    echo ""
    [ $deleted_count -gt 0 ] && log_success "已清理 $deleted_count 个旧版本" || log_info "没有需要清理的版本"
}

create_release() {
    echo ""
    log_info "步骤 3/4: 创建 Release"
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
    log_info "步骤 4/4: 上传文件到 Release"
    
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

set_public_repo() {
    echo ""
    log_info "修改仓库为公开"

    local update_response=$(curl -s -X PATCH \
        "https://gitee.com/api/v5/repos/${REPO_PATH}?access_token=${GITEE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "'"${REPO_NAME}"'",
            "description": "'"${REPO_DESC}"'",
            "private": false
        }')

    # 打印返回结果以便调试
    log_debug "响应: $update_response"

    if echo "$update_response" | jq -e '.private' | grep -q "false"; then
        log_success "仓库已修改为公开"
    else
        log_warning "仓库仍然是私有，可能需要手动设置"
    fi
}

#  主函数 
main() {
    echo "${PLATFORM_TAG} Release 发布脚本"
    echo "仓库: ${REPO_PATH}"
    echo "标签: ${TAG_NAME}"

    check_token
    ensure_repository
    cleanup_old_tags
    create_release
    upload_files
    verify_release
    set_public_repo
    
    log_success "🎉 发布完成"
    echo "Release 地址:"
    echo "  https://gitee.com/${REPO_PATH}/releases/tag/${TAG_NAME}"
    echo ""
}

main "$@"
