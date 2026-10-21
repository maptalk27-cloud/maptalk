# MapTalk 亲友内测部署

目标是先让两台真机使用真实账号、照片和地图，再邀请 10–20 人。代码和模板不会自动创建云服务；云账单、Apple 账号配置和真机验收需要单独完成。

当前 AWS 路线见 [AWS 部署与费用说明](deploy/aws/README.md)，selected Region 为 `us-east-2`。先确认预算、域名，再部署。下文的 Render 操作保留为旧的可选路线，不要与 AWS 步骤混用。

## 第一版范围

- Apple 登录、一次性邀请码、POI／Reel 照片和文字、MyMap、公开地图。
- 私密内容仅本人可读。公开内容面向所有已获邀请的测试成员，不代表仅好友可见。
- Public 发布成功后立即进入动态和公开地图；Private 只保存在自己的 MyMap。动态仍遵循原有有效期，过期不会删除 MyMap 记录。举报、屏蔽、违规内容下架仍保留，不再设置发布前人工放行。
- 支持改私密、删除帖子、举报、屏蔽和删除账号。MyMap 原来的 Remove 仍只是从自己的归档隐藏，不是撤回公开内容。
- 支持修改用户名和上传头像，资料保存到真实账号。当前源码另含 POI / Reel 短视频支持，需完成下方 schema 9 发布验收后才算线上可用。Bubble、聊天、好友、点赞、评论、推送暂不作为可用后端功能。Collection 只在本设备保存，不跨设备同步。Demo 继续展示原设计，不会和真实数据混用。

## 短视频更新（2026-10-21 已部署，真机验收待用户操作）

现有 EC2 已升级到 schema 9，87 项目标 Linux ARM64 隔离测试通过，60 秒 / 720p / 60fps 合成视频按生产资源上限处理成功（9.4 秒）。切换前完成实际 S3 加密备份取回、认证解密、完整表内容校验和迁移演练；原有 1 个用户、9 条记录、8 个媒体的内容保持一致。公开 HTTPS 健康与未认证访问限制通过；不等同于两台真机或真实用户视频发布验收。记录见 `deploy/aws/deployed-resources.json`。

- 继续使用现有单实例与 50 MiB / 用户额度，不引入转码云服务、不提高云配额；单个视频最多 20 MiB / 60 秒 / 720p。实际存储和流量仍会随使用增长，额度不是账单硬上限。
- 使用更新后的 Dockerfile 构建：运行镜像须包含 FFmpeg 和 FFprobe；不能只把 JS 拷进旧镜像。先在目标 Linux ARM64 镜像中跑视频处理、权限、范围请求、重试和迁移测试，再替换服务。
- schema 8→9 只扩展媒体类型约束，但会重建媒体表。切换前验证加密备份与恢复、磁盘剩余空间（需要复制现有媒体表）、完整数据库内容和外键；迁移后核对旧记录 / 图片 / 头像 / 重试映射未变化。旧 schema 8 服务不能直接读取 schema 9，回退不能只换旧镜像或覆盖备份来丢弃后续写入。
- 容器资源上限不变：视频同时仅处理 1 个，最长解码 45 秒，临时输入 / 输出总计约 40 MiB，保留现有 64 MiB tmpfs。不要绕过损坏文件、类型、时长、画幅或存储限额校验。
- 两台真实账号验证：POI 与 Reel 图片 / 视频混排；横屏 / 竖屏和音频；弱网排队重试不重复；私人 GET / HEAD / Range 不外泄；公开 / 改私密 / 删除即时影响访问；50 MiB 满额提示能恢复。iPhone 验收由用户操作，不自动操作其手机。

## 先准备这四项

1. Apple Developer Program 可正常使用；App ID 的 Bundle ID 与工程一致，启用 Sign in with Apple。
2. Apple Team ID、Key ID、Sign in with Apple 的 `.p8` 私钥。私钥只能放服务器，不放 App 或 Git。
3. 一个准备使用的 HTTPS 服务地址，以及真实可访问的隐私政策、支持联系页面。政策应说明位置／照片／账号信息、测试成员可见范围、存储地区、审核、删除与备份保留；不要发布仍带占位符的页面。
4. 确认云预算、测试地区和审核安排。AWS 选择 `us-east-2`；旧 Render 模板为 Oregon。两者都不等于已保证中国大陆或欧洲网络表现。先用最终地址在测试者的 Wi-Fi 和蜂窝网络上实测，再决定是否扩大范围。

Google 和微信的代码保留，可稍后填写已申请的平台配置；真实模式只显示服务端及客户端均已配置的方式。不同平台登录暂不自动合并账号，第一轮统一 Apple，避免同一个人进入多个账号。

## Render 备选路线（不是当前 AWS 步骤）

仓库根目录的 `render.yaml` 是 Render 单实例模板：Node 24、付费计算实例和 10 GB 持久磁盘，自动部署关闭。创建前查看控制台显示的价格并确认费用。SQLite 必须保留单实例；磁盘只持久保存挂载路径内的数据。配置字段见 [Render Blueprint 文档](https://render.com/docs/blueprint-spec)，磁盘限制见 [持久磁盘说明](https://render.com/docs/disks)。

1. 将代码保存并推送至准备部署的私有仓库；在 Render 连接该仓库，按模板创建服务。不要把本机测试数据库上传。
2. 填写下面的环境变量。`MAPTALK_PUBLIC_ORIGIN` 使用最终 HTTPS origin，无末尾 `/`、路径或参数。如果创建时地址还未知，先让服务保持未就绪，拿到真实地址后补齐并重新部署。
3. 在服务的 Secret Files 中添加 `apple-sign-in.p8`，粘贴 Apple 提供的私钥。运行时路径为 `/etc/secrets/apple-sign-in.p8`，见 [Render secret files](https://render.com/docs/configure-environment-variables)。私钥缺失时服务会拒绝启动，不会降级成演示登录。
4. 配置完成后手动部署。访问最终地址的 `/health`，应返回 `mode: private-beta`；仅返回健康状态不代表登录、备份和权限已验收。

| 配置 | 值或用途 |
| --- | --- |
| `MAPTALK_MODE` | `beta` |
| `MAPTALK_BIND` | Render 上为 `0.0.0.0`，由平台终结 HTTPS；不要将 Node HTTP 端口直接开放公网 |
| `MAPTALK_PUBLIC_ORIGIN` | 例如 `https://你的服务.onrender.com`，不是占位地址 |
| `MAPTALK_DATABASE` | `/var/data/maptalk.sqlite`，首次必须新空库 |
| `MAPTALK_BACKUP_DIRECTORY` | `/var/data/backups` |
| `MAPTALK_APPLE_CLIENT_ID` | iOS Bundle ID |
| `MAPTALK_APPLE_TEAM_ID` | Apple Team ID |
| `MAPTALK_APPLE_KEY_ID` | Apple 登录密钥 ID |
| `MAPTALK_APPLE_PRIVATE_KEY_PATH` | `/etc/secrets/apple-sign-in.p8` |
| `MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY` | 32 个随机字节的标准 base64，用于加密 Apple refresh token |
| `MAPTALK_BACKUP_ENCRYPTION_KEY` | 另一份独立的 32 字节 base64 密钥，用于备份 |

两份加密密钥分别在自己受控的终端生成，再存入服务器秘密配置和密码管理器，不发送到聊天、不提交 Git：

```sh
openssl rand -base64 32
```

重启或重新部署时保留相同密钥，不能每次重新生成。备份密钥丢失会无法恢复；Apple token 密钥丢失会影响授权撤销和删号。数据、备份以及密钥都需要明确的负责人。

## 连接 iPhone

将 `Config/Backend.local.xcconfig.example` 复制为 `Config/Backend.local.xcconfig`，填写真实 API、隐私政策和支持页面 HTTPS URL。模板中的 `https:/$()/` 是 xcconfig 转义方式，保留这种写法。

该文件被 Git 忽略。Release 没有 Demo、没有密码测试入口，也不会连 `127.0.0.1`；地址缺失时显示配置错误。CI 或另一台 Mac 构建时也必须提供同样的公开配置，不能只在当前 Mac 设置后就以为所有打包都可用。

在两台真机上先验证 Apple 登录、发布与隐私，再考虑 TestFlight。Apple Developer 会员已开通仍需要实际配置 Sign in with Apple，不能用模拟器通过代替真实授权验收。

当前工程最低要求 iOS 26。先确认亲友设备版本；兼容更旧 iOS 是另一项工作，本轮没有降低系统要求。

## 邀请与内容管理

以下命令在服务器服务目录运行，继承服务的 `MAPTALK_DATABASE`；没有公开的管理员 HTTP 接口。

```sh
npm run beta -- issue --hours 168
```

输出一份单人、一次性、七天有效的邀请码。私发给指定测试者，不建公开邀请链接。用户登录后填码进入；未获邀请的账号不能读写内容。

```sh
npm run beta -- revoke --user 用户UUID
npm run beta -- pending
npm run beta -- reports
```

公开内容不再需要手动批准。以下命令仅用于举报后的内容处理；`pending` 保留用于旧版本诊断。需要核查照片时，将单张导出到管理员私有临时路径，查看后删除副本，不要放公网文件夹；`reject` 下架违规内容，`approve` 仅用于经确认后的恢复：

```sh
npm run beta -- export-media --media 媒体UUID --output /tmp/review-photo.jpg
npm run beta -- approve --memory 记录UUID
npm run beta -- reject --memory 记录UUID
```

撤销邀请会阻止现有会话继续访问，并隐藏该成员的公开内容。举报不会自动删除帖子，管理员必须实际处理。屏蔽双向隔离公开内容；这些操作无法撤回别人已经截图或离线保存的副本。

## 备份与恢复演练

服务启动后立即尝试备份，此后每 24 小时一次，保留最新七份加密快照。正常备份流程会删除临时明文；进程被强制终止时可能留下仅服务用户可读的临时目录，需要运维检查。

默认／Render 自动备份仍在同一块磁盘，**不是异地备份**。AWS 模式另外上传到同 Region 私有 S3，见 [AWS 备份说明](deploy/aws/README.md#备份与恢复)。无论哪条路线，邀请亲友前必须确认另一处受控存储确实有成功备份并完成恢复演练；密钥与备份分开保存。不要复制运行中的 SQLite 主文件来代替在线备份。

10 GB 只是初始磁盘容量。七份完整备份、在线数据库和备份临时文件会同时占空间；监控使用率，达到 70% 前评估扩容，不要把每人 50 MiB 的上传额度当成整个服务只占这么多空间。

手动创建和恢复均不会覆盖已有目标：

```sh
npm run backup:encrypted -- create /var/data/backups/manual-new.mtbak
npm run backup:encrypted -- restore /var/data/backups/manual-new.mtbak /var/data/restore-check.sqlite
```

恢复先验证加密完整性和 SQLite 完整性，但还需验证业务数据。演练用新路径，不替换运行中的数据库。实际灾难恢复前停止服务，核对恢复点之后的删号／撤回／屏蔽操作，并在重新开放前补做；旧备份会包含旧权限和旧会话。

删除账号会清除在线库里的账号、记录和照片，并尝试撤销 Apple 授权；已有备份不即时重写。按政策保留、到期删除所有本地和异地副本；手动导出的审核照片也需人工删除。恢复旧备份绝不能把已删除的内容直接重新公开。

## 发邀请前验收

- [ ] Apple 登录、取消授权、退出重进；未邀请者无法读取内容，邀请码只能给一个账号用。
- [ ] A 发私密照片，B 无法从地图、主页或媒体 URL 读取；A 发 Public，B 无需等待审核即可看到。下架内容不可被他人读取。
- [ ] 用户名和头像保存后重新登录仍保留；重名提示不丢失编辑内容；其他测试成员能看到最新公开资料。
- [ ] A 改私密／删帖，B 刷新后无法再读；MyMap Remove 仅隐藏归档。
- [ ] 举报可查、屏蔽双向生效；撤销成员后其现有会话被拒绝。
- [ ] Apple 用户删号成功；Apple 撤销接口失败时不会谎报删除成功，能够重试。
- [ ] 杀掉 App、断网重试、上传重复请求和重新部署不会丢数据或产生重复帖子。
- [ ] 加密备份有成功文件，完成异地复制和新路径恢复演练。
- [ ] 隐私／支持页面可访问；有人每天处理审核和举报。
- [ ] 两台真机及计划邀请地区的网络可用，再制作 TestFlight 包。

这些勾选是上线门槛，不是本地自动化测试会自动完成的事项。
