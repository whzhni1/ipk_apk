
## Fork本项目后需要做些什么？

### 1. 修改工作流文件中的用户名
修改 `.github/workflows/` 目录下的所有工作流文件，将 `whzhni` 替换为你自己的 对应平台的 用户名。

### 2. 注意同步配置
特别注意 `sync-upstream-releases.yml` 文件中的配置：

- {github_owner: "whzhni1", github_repo: "luci-app-tailscale", local_name: "tailscale"}

⚠️ **注意**：`whzhni1` 这个用户名不能修改。

### 3. 注册代码托管平台并配置令牌

#### 3.1 注册平台并创建令牌
注册以下平台并创建访问令牌：
- [gitee](https://gitee.com)
- [gitcode](https://gitcode.com) 
- [gitlab](https://gitlab.com)

在创建令牌时，请勾选所有权限，然后复制令牌备用，- [创建令牌指南](./tokens_README.md)。

#### 3.2 配置 GitHub Secrets
回到 GitHub 仓库，按以下步骤配置：
1. 点击 `Settings` →`Actions→General`→`Read and write permissions`→`Allow GitHub Actions to create and approve pull requests` →`Save`
2. 点击`Secrets and variables` → `Actions`
3. 点击 `New repository secret`
4. 分别添加以下三个 secret：
   - **Name**: `GITCODE_TOKEN`，**Secret**: 你的 gitcode 访问令牌
   - **Name**: `GITEE_TOKEN`，**Secret**: 你的 gitee 访问令牌  
   - **Name**: `GITLAB_TOKEN`，**Secret**: 你的 gitlab 访问令牌

#### 3.3 测试 Release 工作流
1. 点击 Actions
2. 运行 `Release 脚本` 工作流
3. 在项目名称处填写你 Fork 后的本项目名称
4. 运行工作流，系统将自动在 gitcode、gitee、gitlab 创建对应项目

#### 3.4 同步上游插件
运行 `同步上游发布插件` 工作流，系统将：
- 批量同步多个插件到 gitcode、gitee、gitlab
- 自动创建仓库并发布 Releases


# 插件配置参数说明 不是必须设置可按需要修改

## 参数说明表格

| 参数           | 类型     | 说明         | 作用                     |
|----------------|----------|--------------|--------------------------|
| github_owner   | 字符串   | 上游作者名   | 拉取上游项目             |
| github_repo    | 字符串   | 上游仓库名   | 指定要同步的仓库         |
| local_name     | 字符串   | 本地仓库名   | 同步后在本地仓库显示名称 |
| filter_include | 字符串   | 包含过滤规则 | 只保留匹配的文件         |
| filter_exclude | 字符串   | 排除过滤规则 | 排除匹配的文件           |

## 插件配置示例表格

| 插件名     | 配置实例                                                                         | 匹配说明                                                                 |
|------------|----------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| OpenClash  | `{github_owner: "vernesong", github_repo: "OpenClash", local_name: "luci-app-openclash"}` | 无过滤，同步所有文件                                                     |
| Tailscale  | `{github_owner: "whzhni1", github_repo: "luci-app-tailscale", local_name: "tailscale"}`   | 名称转为 tailscale，同步所有文件                                         |
| Lucky      | `{github_owner: "gdy666", github_repo: "luci-app-lucky", local_name: "lucky", filter_include: "luci-app-*:1 luci-i18n-*:1 *{VERSION}*wanji*"}` | 名称转为 lucky，匹配1个luci-app，1个luci-i18n，匹配最新版本含wanji的文件 |
| Aurora     | `{github_owner: "eamonxg", github_repo: "luci-theme-aurora"}`                            | 无过滤，使用默认名称，同步所有文件                                       |
| Passwall   | `{github_owner: "xiaorouji", github_repo: "openwrt-passwall", local_name: "luci-app-passwall", filter_exclude: "luci-19.07* *.zip"}` | 名称转为 luci-app-passwall，排除19.07版本和zip文件                       |
| Passwall2  | `{github_owner: "xiaorouji", github_repo: "openwrt-passwall2", local_name: "luci-app-passwall2", filter_exclude: "luci-19.07* *.zip"}` | 名称转为 luci-app-passwall2，排除19.07版本和zip文件                      |
