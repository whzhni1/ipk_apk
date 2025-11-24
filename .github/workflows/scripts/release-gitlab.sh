#!/bin/bash

set -e

# 环境变量
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
USERNAME="${USERNAME:-}"
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
PROJECT_ID=""
PACKAGE_NAME="release-files"
ASSETS_LINKS="[]"
TAG="[GitLab]"

# 日志
log() { echo -e "\033[0;36m${TAG}[INFO]\033[0m $*" >&2; }
success() { echo -e "\033[0;32m${TAG}[✓]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m${TAG}[!]\033[0m $*" >&2; }
err() { echo -e "\033[0;31m${TAG}[✗]\033[0m $*" >&2; }
fatal() { err "$*"; exit 1; }

# API 调用
api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
    [ "$method" = "POST" ] && args+=(-X POST -H "Content-Type: application/json" -d "$data")
    [ "$method" = "PATCH" ] && args+=(-X PATCH -H "Content-Type: application/json" -d "$data")
    [ "$method" = "DELETE" ] && args+=(-X DELETE -o /dev/null -w "%{http_code}")
    curl "${args[@]}" "${API_BASE}${endpoint}"
}

urlencode() { echo -n "$1" | jq -sRr @uri; }

check_env() {
    [ -z "$GITLAB_TOKEN" ] && fatal "GITLAB_TOKEN 未设置"
    [ -z "$USERNAME" ] || [ -z "$REPO_NAME" ] && fatal "USERNAME 或 REPO_NAME 未设置"
    success "配置检查通过"
}

ensure_repo() {
    log "步骤 1/4: 检查仓库"
    local resp=$(api GET "/projects/$(urlencode "$REPO_PATH")")
    
    if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then
        PROJECT_ID=$(echo "$resp" | jq -r '.id')
        local vis=$(echo "$resp" | jq -r '.visibility')
        success "仓库已存在 (ID: $PROJECT_ID, 可见性: $vis)"
        [ "$vis" = "public" ] && return 0 || return 1
    fi
    
    warn "仓库不存在，创建中..."
    local vis=$([ "$REPO_PRIVATE" = "false" ] && echo "public" || echo "private")
    local payload=$(jq -n --arg n "$REPO_NAME" --arg d "$REPO_DESC" --arg v "$vis" \
        '{name:$n, description:$d, visibility:$v, initialize_with_readme:false}')
    
    resp=$(api POST "/projects" "$payload")
    PROJECT_ID=$(echo "$resp" | jq -r '.id // empty')
    [ -z "$PROJECT_ID" ] && fatal "创建仓库失败"
    success "仓库已创建 (ID: $PROJECT_ID)"
    
    log "初始化仓库..."
    local tmp="${RUNNER_TEMP:-/tmp}/gitlab-$$"
    mkdir -p "$tmp" && cd "$tmp"
    
    cat > README.md <<EOF
# ${REPO_NAME}

${REPO_DESC}

## 📦 Release
访问 [Releases](${GITLAB_URL}/${REPO_PATH}/-/releases) 下载构建产物。
EOF
    
    git init -b "$BRANCH" -q
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git remote add origin "https://oauth2:${GITLAB_TOKEN}@${GITLAB_URL#https://}/${REPO_PATH}.git"
    git add . && git commit -m "Initial commit" -q
    git push origin "$BRANCH" --force 2>&1 | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" || fatal "初始化失败"
    
    cd - >/dev/null && rm -rf "$tmp"
    success "仓库初始化完成"
    [ "$vis" = "public" ] && return 0 || return 1
}

cleanup_tags() {
    log "步骤 2/4: 清理旧标签"
    local tags=$(api GET "/projects/$PROJECT_ID/repository/tags" | jq -r '.[].name // empty')
    [ -z "$tags" ] && { log "无需清理"; return; }
    
    local count=0
    while IFS= read -r tag; do
        [ -z "$tag" ] || [ "$tag" = "$TAG_NAME" ] && continue
        echo "$tag" | grep -qE '^(v[0-9]|[0-9])' || continue
        
        warn "清理: $tag"
        local code=$(api DELETE "/projects/$PROJECT_ID/repository/tags/$(urlencode "$tag")")
        if [ "$code" = "204" ] || [ "$code" = "200" ]; then
            success "  已删除"
            count=$((count + 1))
        else
            warn "  删除失败"
        fi
        sleep 0.5
    done <<< "$tags"
    
    [ $count -gt 0 ] && success "已清理 $count 个旧版本" || log "无需清理"
}

upload_files() {
    log "步骤 3/4: 上传文件"
    [ -z "$UPLOAD_FILES" ] && { log "无文件需要上传"; return; }
    
    local uploaded=0 failed=0
    IFS=' ' read -ra files <<< "$UPLOAD_FILES"
    
    for file in "${files[@]}"; do
        [ -z "$file" ] && continue
        if [ ! -f "$file" ]; then
            warn "文件不存在: $file"
            failed=$((failed + 1))
            continue
        fi
        
        local name=$(basename "$file")
        log "[$((uploaded + failed + 1))/${#files[@]}] $name ($(du -h "$file" | cut -f1))"
        
        local url="${API_BASE}/projects/$PROJECT_ID/packages/generic/$PACKAGE_NAME/$TAG_NAME/$name"
        local resp=$(curl -s -w "\n%{http_code}" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" --upload-file "$file" "$url")
        local code=$(echo "$resp" | tail -n1)
        
        if [ "$code" = "201" ]; then
            local dl_url="${API_BASE}/projects/$PROJECT_ID/packages/generic/$PACKAGE_NAME/$TAG_NAME/$name"
            ASSETS_LINKS=$(echo "$ASSETS_LINKS" | jq --arg n "$name" --arg u "$dl_url" \
                '. += [{name:$n, url:$u, link_type:"package"}]') || {
                err "添加链接失败"
                failed=$((failed + 1))
                continue
            }
            success "上传成功"
            uploaded=$((uploaded + 1))
        else
            err "上传失败 (HTTP $code)"
            failed=$((failed + 1))
        fi
    done
    
    echo "" >&2
    [ $uploaded -eq ${#files[@]} ] && success "全部上传成功: $uploaded/${#files[@]}" || \
        warn "上传完成: 成功 $uploaded, 失败 $failed"
}

create_release() {
    log "步骤 4/4: 创建 Release (标签: $TAG_NAME)"
    
    local existing=$(api GET "/projects/$PROJECT_ID/releases/$TAG_NAME")
    if echo "$existing" | jq -e '.tag_name' >/dev/null 2>&1; then
        warn "Release 已存在"
        [ "$ASSETS_LINKS" = "[]" ] && return
        
        log "添加文件..."
        local count=$(echo "$ASSETS_LINKS" | jq 'length')
        local added=0
        for ((i=0; i<count; i++)); do
            local link=$(echo "$ASSETS_LINKS" | jq -c ".[$i]")
            api POST "/projects/$PROJECT_ID/releases/$TAG_NAME/assets/links" "$link" >/dev/null && \
                added=$((added + 1))
        done
        success "已添加 $added/$count 个文件"
        return
    fi
    
    local tag_check=$(api GET "/projects/$PROJECT_ID/repository/tags/$(urlencode "$TAG_NAME")")
    if ! echo "$tag_check" | jq -e '.name' >/dev/null 2>&1; then
        local tag_payload=$(jq -n --arg t "$TAG_NAME" --arg r "$BRANCH" '{tag_name:$t, ref:$r}')
        api POST "/projects/$PROJECT_ID/repository/tags" "$tag_payload" >/dev/null || fatal "创建标签失败"
    fi
    
    local payload=$(jq -n --arg t "$TAG_NAME" --arg n "$RELEASE_TITLE" --arg d "$RELEASE_BODY" \
        --argjson l "$ASSETS_LINKS" '{tag_name:$t, name:$n, description:$d, assets:{links:$l}}')
    local resp=$(api POST "/projects/$PROJECT_ID/releases" "$payload")
    echo "$resp" | jq -e '.tag_name' >/dev/null 2>&1 || fatal "创建 Release 失败"
    
    local count=$(echo "$resp" | jq '.assets.links | length')
    success "Release 创建成功 (包含 $count 个附件)"
}

set_public() {
    log "设置仓库为公开"
    local resp=$(api PATCH "/projects/$PROJECT_ID" '{"visibility":"public"}')
    echo "$resp" | jq -e '.visibility' | grep -q "public" && success "已设置为公开" || warn "设置失败"
}

main() {
    echo "$TAG Release 发布脚本" >&2
    echo "仓库: $REPO_PATH, 标签: $TAG_NAME" >&2
    echo "" >&2
    
    check_env
    ensure_repo && is_public=0 || is_public=1
    cleanup_tags
    upload_files
    create_release
    [ $is_public -ne 0 ] && set_public
    
    success "🎉 发布完成"
    echo "Release: ${GITLAB_URL}/${REPO_PATH}/-/releases/${TAG_NAME}" >&2
}

main "$@"
