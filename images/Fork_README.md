
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

在创建令牌时，请勾选所有权限，然后复制令牌备用，- [创建令牌指南](./images/tokens_README.md)。

#### 3.2 配置 GitHub Secrets
回到 GitHub 仓库，按以下步骤配置：
1. 点击 `Settings` → `Secrets and variables` → `Actions`
2. 点击 `New repository secret`
3. 分别添加以下三个 secret：
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

