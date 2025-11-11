#!/bin/bash

# ========================================
# GitCode Release 发布脚本
# ========================================

set -e  # 遇到错误立即退出

# ========================================
# 配置区域 - 请根据实际情况修改
# ========================================

# GitCode Token (必须配置)
GITCODE_TOKEN="${GITCODE_TOKEN:-}"

# 仓库配置
USERNAME="whzhni"
REPO_NAME="test-release"  # 测试仓库名
REPO_DESC="测试 GitCode Release 自动发布"
REPO_PRIVATE="false"  # true 或 false
BRANCH="main"

# Release 配置
TAG_NAME="v1.0.0"  # 要发布的标签
RELEASE_TITLE="测试发布 v1.0.0"
RELEASE_BODY="这是一个测试发布

## 更新内容
- 测试功能 A
- 测试功能 B
- 测试功能 C"

# 要上传的文件（空格分隔，留空则不上传）
UPLOAD_FILES="README.md"  # 示例：上传 README.md

# API 配置
API_BASE="https://gitcode.com/api/v4"
PROJECT_ID_ENCODED="${USERNAME}%2F${REPO_NAME}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# ========================================
# 工具函数
# ========================================

# 打印信息
log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

log_step() {
    echo -e "${MAGENTA}[STEP]${NC} $1"
}

# 打印分隔线
print_separator() {
    echo ""
    echo "========================================="
    echo "$1"
    echo "========================================="
    echo ""
}

# 检查 Token
check_token() {
    if [ -z "$GITCODE_TOKEN" ]; then
        log_error "GITCODE_TOKEN 未设置"
        log_info "请设置环境变量: export GITCODE_TOKEN='your_token'"
        exit 1
    fi
    log_success "Token 已配置"
}

# 发送 GET 请求
api_get() {
    local url="$1"
    log_debug "GET: $url"
    
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer ${GITCODE_TOKEN}" \
        -H "Content-Type: application/json" \
        "$url")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    log_debug "HTTP Code: $http_code"
    if [ ${#body} -gt 200 ]; then
        log_debug "Response: ${body:0:200}..."
    else
        log_debug "Response: $body"
    fi
    
    echo "$body"
    return $([ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] && echo 0 || echo 1)
}

# 发送 POST 请求
api_post() {
    local url="$1"
    local data="$2"
    log_debug "POST: $url"
    
    if [ ${#data} -gt 200 ]; then
        log_debug "Data: ${data:0:200}..."
    else
        log_debug "Data: $data"
    fi
    
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${GITCODE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "$url")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    log_debug "HTTP Code: $http_code"
    if [ ${#body} -gt 200 ]; then
        log_debug "Response: ${body:0:200}..."
    else
        log_debug "Response: $body"
    fi
    
    echo "$body"
    return $([ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] && echo 0 || echo 1)
}

# 发送 PUT 请求
api_put() {
    local url="$1"
    local data="$2"
    log_debug "PUT: $url"
    
    if [ ${#data} -gt 200 ]; then
        log_debug "Data: ${data:0:200}..."
    else
        log_debug "Data: $data"
    fi
    
    response=$(curl -s -w "\n%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer ${GITCODE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "$url")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    log_debug "HTTP Code: $http_code"
    if [ ${#body} -gt 200 ]; then
        log_debug "Response: ${body:0:200}..."
    else
        log_debug "Response: $body"
    fi
    
    echo "$body"
    return $([ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] && echo 0 || echo 1)
}

# 发送 DELETE 请求
api_delete() {
    local url="$1"
    log_debug "DELETE: $url"
    
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE \
        -H "Authorization: Bearer ${GITCODE_TOKEN}" \
        "$url")
    
    log_debug "HTTP Code: $http_code"
    
    return $([ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] && echo 0 || echo 1)
}

# 上传文件
api_upload() {
    local file="$1"
    local url="${API_BASE}/projects/${PROJECT_ID_ENCODED}/uploads"
    
    log_debug "UPLOAD: $url"
    log_debug "File: $file"
    
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${GITCODE_TOKEN}" \
        -F "file=@${file}" \
        "$url")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    log_debug "HTTP Code: $http_code"
    if [ ${#body} -gt 200 ]; then
        log_debug "Response: ${body:0:200}..."
    else
        log_debug "Response: $body"
    fi
    
    echo "$body"
    return $([ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] && echo 0 || echo 1)
}

# ========================================
# 主要功能函数
# ========================================

# 1. 检查仓库是否存在
check_repository() {
    print_separator "步骤 1/9: 检查仓库是否存在"
    log_step "检查 GitCode 仓库: ${USERNAME}/${REPO_NAME}"
    
    local url="${API_BASE}/projects/${PROJECT_ID_ENCODED}"
    
    if response=$(api_get "$url"); then
        log_success "仓库已存在: ${USERNAME}/${REPO_NAME}"
        
        # 提取仓库信息
        repo_id=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://g')
        repo_visibility=$(echo "$response" | grep -o '"visibility":"[^"]*"' | sed 's/"visibility":"//g' | sed 's/"//g')
        repo_default_branch=$(echo "$response" | grep -o '"default_branch":"[^"]*"' | sed 's/"default_branch":"//g' | sed 's/"//g')
        
        log_info "  ├─ 仓库 ID: $repo_id"
        log_info "  ├─ 可见性: $repo_visibility"
        log_info "  └─ 默认分支: $repo_default_branch"
        
        return 0
    else
        log_warning "仓库不存在，需要创建"
        return 1
    fi
}

# 2. 创建仓库
create_repository() {
    print_separator "步骤 2/9: 创建仓库"
    log_step "创建新仓库: ${USERNAME}/${REPO_NAME}"
    
    local visibility="public"
    [ "$REPO_PRIVATE" == "true" ] && visibility="private"
    
    local data="{
        \"name\": \"${REPO_NAME}\",
        \"description\": \"${REPO_DESC}\",
        \"visibility\": \"${visibility}\",
        \"initialize_with_readme\": false
    }"
    
    log_info "  ├─ 仓库名: ${REPO_NAME}"
    log_info "  ├─ 可见性: $visibility"
    log_info "  └─ 描述: ${REPO_DESC}"
    
    if response=$(api_post "${API_BASE}/projects" "$data"); then
        log_success "仓库创建成功！"
        
        repo_id=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://g')
        web_url=$(echo "$response" | grep -o '"web_url":"[^"]*"' | sed 's/"web_url":"//g' | sed 's/"//g')
        
        log_info "  ├─ 仓库 ID: $repo_id"
        log_info "  └─ 地址: $web_url"
        
        log_warning "等待 5 秒，确保仓库完全创建..."
        sleep 5
        log_success "等待完成"
        
        return 0
    else
        log_error "仓库创建失败"
        return 1
    fi
}

# 3. 检查分支是否存在
check_branch() {
    print_separator "步骤 3/9: 检查分支是否存在"
    log_step "检查分支: ${BRANCH}"
    
    local url="${API_BASE}/projects/${PROJECT_ID_ENCODED}/repository/branches/${BRANCH}"
    
    if response=$(api_get "$url"); then
        log_success "分支已存在: ${BRANCH}"
        
        commit_sha=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//g' | sed 's/"//g')
        commit_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//g' | sed 's/"//g')
        
        log_info "  ├─ 最新提交: ${commit_sha:0:8}"
        log_info "  └─ 提交信息: $commit_msg"
        
        return 0
    else
        log_warning "分支不存在，需要创建"
        return 1
    fi
}

# 4. 创建分支
create_branch() {
    print_separator "步骤 4/9: 创建分支"
    log_step "创建分支: ${BRANCH}"
    
    # 检查是否在 git 仓库中
    if [ ! -d ".git" ]; then
        log_info "  ├─ 初始化 Git 仓库"
        git init
    fi
    
    # 配置 Git
    log_info "  ├─ 配置 Git 用户信息"
    git config user.name "gitcode-bot"
    git config user.email "bot@gitcode.com"
    
    # 创建 README
    if [ ! -f "README.md" ]; then
        log_info "  ├─ 创建 README.md"
        cat > README.md << EOF
# ${REPO_NAME}

${REPO_DESC}

## 自动创建

此仓库由脚本自动创建于 $(date +'%Y-%m-%d %H:%M:%S')
EOF
    fi
    
    # 添加并提交
    git add -A
    
    if git diff --cached --quiet; then
        log_info "  ├─ 创建空提交"
        git commit --allow-empty -m "Initial commit"
    else
        log_info "  ├─ 提交初始文件"
        git commit -m "Initial commit"
    fi
    
    # 设置远程仓库
    if git remote get-url gitcode &>/dev/null; then
        log_info "  ├─ 更新远程仓库地址"
        git remote set-url gitcode "https://oauth2:${GITCODE_TOKEN}@gitcode.com/${USERNAME}/${REPO_NAME}.git"
    else
        log_info "  ├─ 添加远程仓库"
        git remote add gitcode "https://oauth2:${GITCODE_TOKEN}@gitcode.com/${USERNAME}/${REPO_NAME}.git"
    fi
    
    # 推送
    log_info "  └─ 推送到 ${BRANCH} 分支"
    if git push gitcode HEAD:refs/heads/${BRANCH} 2>&1; then
        log_success "分支创建成功！"
        
        log_warning "等待 3 秒，确保分支完全创建..."
        sleep 3
        log_success "等待完成"
        return 0
    else
        log_error "分支创建失败"
        return 1
    fi
}

# 5. 获取所有标签
get_tags() {
    print_separator "步骤 5/9: 获取现有标签"
    log_step "查询现有标签"
    
    local url="${API_BASE}/projects/${PROJECT_ID_ENCODED}/repository/tags"
    
    if response=$(api_get "$url"); then
        # 提取标签名
        tags=$(echo "$response" | grep -o '"name":"[^"]*"' | sed 's/"name":"//g' | sed 's/"//g')
        
        if [ -z "$tags" ]; then
            log_info "  └─ 当前没有标签"
            return 0
        fi
        
        log_info "现有标签列表:"
        local count=0
        while IFS= read -r tag; do
            if [ -n "$tag" ]; then
                count=$((count + 1))
                log_info "  ├─ $tag"
            fi
        done <<< "$tags"
        log_success "共找到 $count 个标签"
        
        echo "$tags"
        return 0
    else
        log_warning "获取标签失败，可能仓库为空"
        return 0
    fi
}

# 6. 删除标签和 Release
delete_old_tags() {
    print_separator "步骤 6/9: 删除旧标签和 Release"
    
    local tags="$1"
    
    if [ -z "$tags" ]; then
        log_info "  └─ 没有需要删除的标签"
        return 0
    fi
    
    log_step "清理旧标签（保留 ${TAG_NAME}）"
    
    local deleted_count=0
    local skipped_count=0
    
    while IFS= read -r tag; do
        if [ -z "$tag" ]; then
            continue
        fi
        
        if [ "$tag" == "$TAG_NAME" ]; then
            log_info "  ├─ 跳过目标标签: $tag"
            skipped_count=$((skipped_count + 1))
            continue
        fi
        
        log_warning "  ├─ 删除标签: $tag"
        
        # 删除 Release
        log_info "     ├─ 删除 Release"
        if api_delete "${API_BASE}/projects/${PROJECT_ID_ENCODED}/releases/${tag}"; then
            log_success "     │  └─ ✓ Release 删除成功"
        else
            log_info "     │  └─ ! Release 不存在或已删除"
        fi
        
        # 删除标签
        log_info "     └─ 删除标签"
        if api_delete "${API_BASE}/projects/${PROJECT_ID_ENCODED}/repository/tags/${tag}"; then
            log_success "        └─ ✓ 标签删除成功"
            deleted_count=$((deleted_count + 1))
        else
            log_error "        └─ ✗ 标签删除失败"
        fi
        
        sleep 2
    done <<< "$tags"
    
    log_success "清理完成: 删除 $deleted_count 个，跳过 $skipped_count 个"
}

# 7. 创建 Release
create_release() {
    print_separator "步骤 7/9: 创建 Release"
    log_step "创建新 Release: ${TAG_NAME}"
    
    # 转义 JSON 字符串
    RELEASE_BODY_ESCAPED=$(echo "$RELEASE_BODY" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    local data="{
        \"tag_name\": \"${TAG_NAME}\",
        \"name\": \"${RELEASE_TITLE}\",
        \"description\": \"${RELEASE_BODY_ESCAPED}\",
        \"ref\": \"${BRANCH}\"
    }"
    
    log_info "  ├─ 标签名: $TAG_NAME"
    log_info "  ├─ 标题: $RELEASE_TITLE"
    log_info "  └─ 目标分支: $BRANCH"
    
    if response=$(api_post "${API_BASE}/projects/${PROJECT_ID_ENCODED}/releases" "$data"); then
        log_success "Release 创建成功！"
        
        tag_name=$(echo "$response" | grep -o '"tag_name":"[^"]*"' | sed 's/"tag_name":"//g' | sed 's/"//g')
        created_at=$(echo "$response" | grep -o '"created_at":"[^"]*"' | sed 's/"created_at":"//g' | sed 's/"//g')
        
        log_info "  ├─ 标签: $tag_name"
        log_info "  ├─ 创建时间: $created_at"
        log_info "  └─ 访问地址: https://gitcode.com/${USERNAME}/${REPO_NAME}/-/releases/${TAG_NAME}"
        
        return 0
    else
        log_error "Release 创建失败"
        return 1
    fi
}

# 8. 上传文件到 Release
upload_files() {
    print_separator "步骤 8/9: 上传文件到 Release"
    
    if [ -z "$UPLOAD_FILES" ]; then
        log_info "  └─ 没有需要上传的文件"
        return 0
    fi
    
    log_step "开始上传文件"
    
    local uploaded_count=0
    local failed_count=0
    local file_links=""
    
    # 使用数组处理文件列表
    IFS=' ' read -ra FILES_ARRAY <<< "$UPLOAD_FILES"
    local total=${#FILES_ARRAY[@]}
    local current=0
    
    for file in "${FILES_ARRAY[@]}"; do
        current=$((current + 1))
        
        if [ ! -f "$file" ]; then
            log_warning "  ├─ [$current/$total] 文件不存在: $file"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        file_size=$(du -h "$file" | cut -f1)
        log_info "  ├─ [$current/$total] 上传: $file ($file_size)"
        
        # 上传文件
        if upload_response=$(api_upload "$file"); then
            file_url=$(echo "$upload_response" | grep -o '"url":"[^"]*"' | sed 's/"url":"//g' | sed 's/"//g' | head -1)
            file_markdown=$(echo "$upload_response" | grep -o '"markdown":"[^"]*"' | sed 's/"markdown":"//g' | sed 's/"//g' | head -1)
            
            if [ -n "$file_url" ]; then
                log_success "     └─ ✓ 上传成功"
                log_debug "        ├─ URL: $file_url"
                log_debug "        └─ Markdown: $file_markdown"
                
                # 收集文件链接
                file_links="${file_links}\\n${file_markdown}"
                
                uploaded_count=$((uploaded_count + 1))
            else
                log_error "     └─ ✗ 上传失败（无效响应）"
                failed_count=$((failed_count + 1))
            fi
        else
            log_error "     └─ ✗ 上传失败"
            failed_count=$((failed_count + 1))
        fi
    done
    
    # 如果有上传成功的文件，更新 Release 描述
    if [ $uploaded_count -gt 0 ]; then
        log_info "  └─ 更新 Release 描述"
        
        # 获取当前 Release 描述
        current_release=$(api_get "${API_BASE}/projects/${PROJECT_ID_ENCODED}/releases/${TAG_NAME}")
        current_desc=$(echo "$current_release" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')
        
        # 添加文件链接到描述
        new_desc="${current_desc}\\n\\n### 📎 附件\\n${file_links}"
        
        # 更新 Release
        update_data="{\"description\": \"${new_desc}\"}"
        
        if api_put "${API_BASE}/projects/${PROJECT_ID_ENCODED}/releases/${TAG_NAME}" "$update_data" > /dev/null; then
            log_success "     └─ ✓ Release 描述已更新"
        else
            log_warning "     └─ ! Release 描述更新失败（文件已上传）"
        fi
    fi
    
    log_success "上传完成: 成功 $uploaded_count 个，失败 $failed_count 个"
}

# 9. 验证 Release
verify_release() {
    print_separator "步骤 9/9: 验证 Release"
    log_step "验证 Release 是否创建成功"
    
    local url="${API_BASE}/projects/${PROJECT_ID_ENCODED}/releases/${TAG_NAME}"
    
    if response=$(api_get "$url"); then
        log_success "Release 验证成功！"
        
        tag_name=$(echo "$response" | grep -o '"tag_name":"[^"]*"' | sed 's/"tag_name":"//g' | sed 's/"//g')
        name=$(echo "$response" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//g' | sed 's/"//g')
        
        log_info "  ├─ 标签: $tag_name"
        log_info "  ├─ 名称: $name"
        log_info "  └─ 地址: https://gitcode.com/${USERNAME}/${REPO_NAME}/-/releases/${TAG_NAME}"
        
        return 0
    else
        log_error "Release 验证失败"
        return 1
    fi
}

# ========================================
# 主流程
# ========================================

main() {
    print_separator "🚀 GitCode Release 发布脚本"
    
    log_info "仓库配置:"
    log_info "  ├─ 用户名: ${USERNAME}"
    log_info "  ├─ 仓库名: ${REPO_NAME}"
    log_info "  ├─ 标签名: ${TAG_NAME}"
    log_info "  └─ 分支: ${BRANCH}"
    
    echo ""
    
    # 检查 Token
    log_step "检查环境配置"
    check_token
    
    echo ""
    
    # 1. 检查仓库
    if ! check_repository; then
        # 2. 创建仓库
        if ! create_repository; then
            log_error "❌ 流程终止：仓库创建失败"
            exit 1
        fi
    fi
    
    # 3. 检查分支
    if ! check_branch; then
        # 4. 创建分支
        if ! create_branch; then
            log_error "❌ 流程终止：分支创建失败"
            exit 1
        fi
    fi
    
    # 5. 获取现有标签
    existing_tags=$(get_tags)
    
    # 6. 删除旧标签
    delete_old_tags "$existing_tags"
    
    # 7. 创建 Release
    if ! create_release; then
        log_error "❌ 流程终止：Release 创建失败"
        exit 1
    fi
    
    # 8. 上传文件
    upload_files
    
    # 9. 验证 Release
    verify_release
    
    print_separator "✅ 所有步骤完成"
    
    log_success "🎉 Release 发布成功！"
    log_info ""
    log_info "📍 访问地址:"
    log_info "   └─ https://gitcode.com/${USERNAME}/${REPO_NAME}/-/releases/${TAG_NAME}"
    echo ""
}

# 执行主流程
main "$@"
