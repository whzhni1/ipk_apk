#!/bin/bash

set -e

# 环境变量配置
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
USERNAME="${USERNAME:-}"
REPO_STATUS="1"
REPO_NAME="${REPO_NAME:-}"
REPO_DESC="${REPO_DESC:-GitLab Release Repository}"
REPO_PRIVATE="${REPO_PRIVATE:-false}"
TAG_NAME="${TAG_NAME:-v1.0.0}"
RELEASE_TITLE="${RELEASE_TITLE:-Release ${TAG_NAME}}"
RELEASE_BODY="${RELEASE_BODY:-Release ${TAG_NAME}}"
BRANCH="${BRANCH:-main}"
UPLOAD_FILES="${UPLOAD_FILES:-}"

API_BASE="${GITLAB_URL}/api/v4"
REPO_PATH="${USERNAME}/${REPO_NAME}"
PROJECT_PATH_ENCODED=""
PROJECT_ID=""
PLATFORM_TAG="[GitLab]"
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

# URL 编码函数
urlencode() {
    local string="$1"
    echo -n "$string" | jq -sRr @uri
}

# API 函数封装
api_get() {
    local endpoint="$1"
    curl -s -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${API_BASE}${endpoint}"
}

api_post() {
    local endpoint="$1"
    local data="$2"
    curl -s -X POST \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "${API_BASE}${endpoint}"
}

api_patch() {
    local endpoint="$1"
    local data="$2"
    curl -s -X PATCH \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "${API_BASE}${endpoint}"
}

api_delete() {
    local endpoint="$1"
    curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${API_BASE}${endpoint}"
}

# 上传文件到项目并返回完整 URL
upload_file_to_project() {
    local file="$1"
    local filename=$(basename "$file")
    
    log_debug "上传文件到项目: $filename" >&2
    
    # 上传文件
    local upload_response=$(curl -s -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        -F "file=@${file}" \
        "${API_BASE}/projects/${PROJECT_ID}/uploads")
    
    # 提取相对 URL
    local relative_url=$(echo "$upload_response" | jq -r '.url // empty')
    
    if [ -z "$relative_url" ] || [ "$relative_url" = "null" ]; then
        log_error "文件上传失败: $filename" >&2
        log_debug "响应: $upload_response" >&2
        return 1
    fi
    
    # 构造完整 URL
    local full_url="${GITLAB_URL}/${REPO_PATH}${relative_url}"
    
    log_debug "文件 URL: $full_url" >&2
    log_debug "文件名: $filename" >&2
    
    # 只输出结果到 stdout（格式：URL|文件名）
    echo "${full_url}|${filename}"
    return 0
}

# 文件上传到 Release
upload_file_to_release() {
    local file="$1"
    local filename=$(basename "$file")
    
    log_info "上传: $filename ($(du -h "$file" | cut -f1))"
    
    # 上传文件到项目并获取 URL
    local result=$(upload_file_to_project "$file")
    local exit_code=$?
    
    if [ $exit_code -ne 0 ] || [ -z "$result" ]; then
        log_error "上传失败"
        return 1
    fi
    
    # 保存到数组供后续关联
    RELEASE_ASSETS+=("$result")
    log_success "上传成功"
    return 0
}

# 创建 Release Link
create_release_link() {
    local file_url="$1"
    local file_name="$2"
    
    # log_debug "关联文件: $file_name -> $file_url"
    
    # 验证参数
    if [ -z "$file_url" ] || [ -z "$file_name" ]; then
        log_error "参数错误: URL='$file_url', Name='$file_name'"
        return 1
    fi
    
    local link_payload=$(jq -n \
        --arg name "$file_name" \
        --arg url "$file_url" \
        '{
            name: $name,
            url: $url,
            link_type: "package"
        }')
    
    # log_debug "Payload: $link_payload"
    
    local response=$(api_post "/projects/${PROJECT_ID}/releases/${TAG_NAME}/assets/links" \
        "$link_payload")
    
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        # log_debug "关联成功: $file_name"
        return 0
    else
        log_error "关联失败: $file_name"
        log_debug "响应: $response"
        return 1
    fi
}

# 核心功能函数
check_token() {
    echo ""
    log_info "检查环境配置"
    
    if [ -z "$GITLAB_TOKEN" ]; then
        log_error "GITLAB_TOKEN 未设置"
        exit 1
    fi
    
    if [ -z "$USERNAME" ] || [ -z "$REPO_NAME" ]; then
        log_error "USERNAME 或 REPO_NAME 未设置"
        exit 1
    fi
    
    PROJECT_PATH_ENCODED=$(urlencode "$REPO_PATH")
    
    log_success "Token 已配置"
}

ensure_repository() {
    echo ""
    log_info "步骤 1/4: 检查仓库"

    local response=$(api_get "/projects/${PROJECT_PATH_ENCODED}")

    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        PROJECT_ID=$(echo "$response" | jq -r '.id')
        log_success "仓库已存在 (ID: ${PROJECT_ID})"
        REPO_STATUS="0"
        return 0
    fi

    log_warning "仓库不存在，创建中..."

    # 确定可见性级别
    local visibility="private"
    if [ "$REPO_PRIVATE" = "false" ]; then
        visibility="public"
    fi

    # 创建项目
    local create_payload=$(jq -n \
        --arg name "$REPO_NAME" \
        --arg desc "$REPO_DESC" \
        --arg vis "$visibility" \
        --arg branch "$BRANCH" \
        '{
            name: $name,
            description: $desc,
            visibility: $vis,
            initialize_with_readme: false,
            default_branch: $branch
        }')

    response=$(api_post "/projects" "$create_payload")

    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        PROJECT_ID=$(echo "$response" | jq -r '.id')
        log_success "仓库创建成功 (ID: ${PROJECT_ID}, 可见性: ${visibility})"
        sleep 3

        # 初始化仓库
        log_info "初始化仓库到分支: ${BRANCH}"

        local temp_dir="${RUNNER_TEMP:-/tmp}/gitlab-init-$$-${RANDOM}"
        mkdir -p "$temp_dir"

        local current_dir=$(pwd)
        cd "$temp_dir"

        git init -q
        git config user.name "GitLab Bot"
        git config user.email "bot@gitlab.com"

        cat > README.md << EOF
# ${REPO_NAME}

${REPO_DESC}

## 📦 Release

本仓库用于自动发布构建产物。
EOF

        git add README.md
        git commit -m "Initial commit" -q

        local git_url="https://oauth2:${GITLAB_TOKEN}@${GITLAB_URL#https://}/${REPO_PATH}.git"
        git remote add origin "$git_url"

        if git push -u origin HEAD:"${BRANCH}" 2>&1 | sed "s/${GITLAB_TOKEN}/***TOKEN***/g"; then
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
    log_info "步骤 2/4: 清理旧标签"

    local deleted_count=0

    # 获取所有标签
    log_debug "获取标签列表..."
    local tags_response=$(api_get "/projects/${PROJECT_ID}/repository/tags")

    if ! echo "$tags_response" | jq -e '.[0]' > /dev/null 2>&1; then
        log_info "没有旧标签"
        return 0
    fi

    local tags=$(echo "$tags_response" | jq -r '.[].name' 2>/dev/null)

    if [ -z "$tags" ]; then
        log_info "没有旧标签"
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

        # 先删除 Release（如果存在）
        log_debug "  检查并删除 Release..."
        local release_check=$(api_get "/projects/${PROJECT_ID}/releases/${tag}")
        if echo "$release_check" | jq -e '.tag_name' > /dev/null 2>&1; then
            api_delete "/projects/${PROJECT_ID}/releases/${tag}" > /dev/null
            log_debug "  Release 已删除"
            sleep 0.5
        fi

        log_debug "  删除标签..."
        local tag_encoded=$(urlencode "$tag")
        local http_code=$(api_delete "/projects/${PROJECT_ID}/repository/tags/${tag_encoded}")

        if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
            log_success "  ✓ 已删除"
            deleted_count=$((deleted_count + 1))
        else
            log_error "  ✗ 删除失败 (HTTP $http_code)"
        fi

        sleep 1
    done <<< "$tags"

    echo ""
    [ $deleted_count -gt 0 ] && log_success "已清理 $deleted_count 个旧版本" || log_info "没有需要清理的版本"
}

create_release() {
    echo ""
    log_info "步骤 3/4: 创建 Release"
    log_info "标签: ${TAG_NAME}"
    log_info "标题: ${RELEASE_TITLE}"
    
    # 检查 Release 是否已存在
    local existing_release=$(api_get "/projects/${PROJECT_ID}/releases/${TAG_NAME}")
    
    if echo "$existing_release" | jq -e '.tag_name' > /dev/null 2>&1; then
        log_warning "Release 已存在"
        return 0
    fi
    
    # 检查标签是否存在
    local tag_encoded=$(urlencode "$TAG_NAME")
    local tag_check=$(api_get "/projects/${PROJECT_ID}/repository/tags/${tag_encoded}")
    
    if ! echo "$tag_check" | jq -e '.name' > /dev/null 2>&1; then

        log_debug "创建标签..."
        local tag_payload=$(jq -n \
            --arg tag "$TAG_NAME" \
            --arg ref "$BRANCH" \
            '{
                tag_name: $tag,
                ref: $ref
            }')
        
        local tag_response=$(api_post "/projects/${PROJECT_ID}/repository/tags" "$tag_payload")
        
        if ! echo "$tag_response" | jq -e '.name' > /dev/null 2>&1; then
            log_error "创建标签失败"
            log_debug "响应: $tag_response"
            exit 1
        fi
        log_debug "标签创建成功"
    fi
    
    # 创建 Release
    local release_payload=$(jq -n \
        --arg tag "$TAG_NAME" \
        --arg name "$RELEASE_TITLE" \
        --arg desc "$RELEASE_BODY" \
        '{
            tag_name: $tag,
            name: $name,
            description: $desc
        }')
    
    local release_response=$(api_post "/projects/${PROJECT_ID}/releases" "$release_payload")
    
    if echo "$release_response" | jq -e '.tag_name' > /dev/null 2>&1; then
        log_success "Release 创建成功"
    else
        log_error "创建 Release 失败"
        log_debug "响应: $release_response"
        exit 1
    fi
}

upload_files() {
    echo ""
    log_info "步骤 4/4: 上传文件到 Release"
    
    if [ -z "$UPLOAD_FILES" ]; then
        log_info "没有文件需要上传"
        return 0
    fi
    
    # 初始化 assets 数组
    RELEASE_ASSETS=()
    
    local uploaded=0
    local failed=0
    
    IFS=' ' read -ra FILES <<< "$UPLOAD_FILES"
    local total=${#FILES[@]}
    
    # 第一步：上传所有文件
    log_info "上传文件到项目..."
    for file in "${FILES[@]}"; do
        [ -z "$file" ] && continue
        
        if [ ! -f "$file" ]; then
            log_warning "文件不存在: $file"
            failed=$((failed + 1))
            continue
        fi
        
        echo ""
        log_info "[$(( uploaded + failed + 1 ))/${total}] $(basename "$file")"
        
        if upload_file_to_release "$file"; then
            uploaded=$((uploaded + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    # 第二步：关联文件到 Release
    if [ ${#RELEASE_ASSETS[@]} -gt 0 ]; then
        echo ""
        log_info "关联文件到 Release..."
        
        local linked=0
        for asset in "${RELEASE_ASSETS[@]}"; do

            local url=$(echo "$asset" | cut -d'|' -f1)
            local name=$(echo "$asset" | cut -d'|' -f2-)
            
            # log_debug "解析结果: URL='$url', Name='$name'"
            
            if create_release_link "$url" "$name"; then
                linked=$((linked + 1))
            fi
        done
        
        log_success "已关联 ${linked}/${#RELEASE_ASSETS[@]} 个文件"
    fi
    
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
    
    local response=$(api_get "/projects/${PROJECT_ID}/releases/${TAG_NAME}")
    
    if echo "$response" | jq -e '.tag_name' > /dev/null 2>&1; then
        log_success "验证成功"
        
        local assets=$(echo "$response" | jq '.assets.links | length')
        log_info "附件数量: $assets"
    else
        log_error "验证失败"
        exit 1
    fi
}

set_public_repo() {
    echo ""
    log_info "修改仓库为公开"

    local update_payload=$(jq -n \
        '{
            visibility: "public"
        }')

    local update_response=$(api_patch "/projects/${PROJECT_ID}" "$update_payload")

    if echo "$update_response" | jq -e '.visibility' | grep -q "public"; then
        log_success "仓库已修改为公开"
    else
        log_warning "仓库仍然是私有，可能需要手动设置"
        log_debug "响应: $update_response"
    fi
}

# 主函数
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
    if [ "$REPO_STATUS" != "0" ]; then
      set_public_repo
    fi

    log_success "🎉 发布完成"
    echo "Release 地址:"
    echo "  ${GITLAB_URL}/${REPO_PATH}/-/releases/${TAG_NAME}"
    echo ""
}

main "$@"
