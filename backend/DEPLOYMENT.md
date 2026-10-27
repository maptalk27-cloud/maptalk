# MapTalk 亲友内测部署

目标是先让两台真机使用真实账号、照片和地图，再邀请 10–20 人。代码和模板不会自动创建云服务；云账单、Apple 账号配置和真机验收需要单独完成。

当前 AWS 路线见 [AWS 部署与费用说明](deploy/aws/README.md)，selected Region 为 `us-east-2`。先确认预算、域名，再部署。下文的 Render 操作保留为旧的可选路线，不要与 AWS 步骤混用。

## 当前媒体额度（2026-10-26）

用户批准后，现有 AWS 后端每账号照片／视频／头像总媒体额度已改为 **1 GiB（1,073,741,824 字节）**。只设置运行环境 `MAPTALK_USER_MEDIA_LIMIT_BYTES` 并用原镜像重新创建 API，schema 12、资源、密钥与单视频 20 MiB 限制不变；没有恢复或覆盖数据库，不需客户端重装。配置／存储／断点上传 24 项测试通过，线上配置、数据库 quick check、健康及未认证访问拦截已验证。原来因额度不足失败的任务需用户在 MyMap 点一次 Retry；这不代表其他上传与后台恢复问题已修复。

后文 50 MiB 为历史发布时的额度。1 GiB 是单账号上限，不是预留空间或扩容：媒体还会进入完整数据库备份，不能按剩余磁盘简单折算可容纳的满额用户数。增加用户前复核磁盘及备份增长，不擅自扩容。证据及配置回退边界见 `deploy/aws/deployed-resources.json` 的 `mediaQuotaUpdate`。

## 第一版范围

- Apple 登录、一次性邀请码、POI／Reel 照片和文字、MyMap、公开地图。
- 私密内容仅本人可读。公开内容面向所有已获邀请的测试成员，不代表仅好友可见。
- Public 发布成功后立即进入动态和公开地图；Private 只保存在自己的 MyMap。后端动态有效期已更新为 72 小时：到期 Reel 退出主地图，POI 保留历史足迹数据；过期不会删除 MyMap 记录。客户端对应展示仍在验收，见下方本轮发布记录。举报、屏蔽、违规内容下架仍保留，不再设置发布前人工放行。
- 支持改私密、删除帖子、举报、屏蔽和删除账号。旧版 MyMap Remove 只是隐藏自己的归档，不代表已从服务端删除或撤回公开内容；本轮删除／地图缓存一致性的客户端改动仍需完成验收。
- 支持修改用户名和上传头像，资料保存到真实账号。POI / Reel 短视频与分段续传已部署，真实手机发布及弱网恢复仍待用户验收。公开帖子／地点的纯文字评论已部署；Bubble、聊天、好友、点赞、推送暂不作为可用后端功能。Collection 只在本设备保存，不跨设备同步。Demo 继续展示原设计，不会和真实数据混用。

## 短视频更新（2026-10-21 已部署，真机验收待用户操作）

现有 EC2 已升级到 schema 9，87 项目标 Linux ARM64 隔离测试通过，60 秒 / 720p / 60fps 合成视频按生产资源上限处理成功（9.4 秒）。切换前完成实际 S3 加密备份取回、认证解密、完整表内容校验和迁移演练；原有 1 个用户、9 条记录、8 个媒体的内容保持一致。公开 HTTPS 健康与未认证访问限制通过；不等同于两台真机或真实用户视频发布验收。记录见 `deploy/aws/deployed-resources.json`。

- 继续使用现有单实例与 50 MiB / 用户额度，不引入转码云服务、不提高云配额；单个视频最多 20 MiB / 60 秒 / 720p。实际存储和流量仍会随使用增长，额度不是账单硬上限。
- 使用更新后的 Dockerfile 构建：运行镜像须包含 FFmpeg 和 FFprobe；不能只把 JS 拷进旧镜像。先在目标 Linux ARM64 镜像中跑视频处理、权限、范围请求、重试和迁移测试，再替换服务。
- schema 8→9 只扩展媒体类型约束，但会重建媒体表。切换前验证加密备份与恢复、磁盘剩余空间（需要复制现有媒体表）、完整数据库内容和外键；迁移后核对旧记录 / 图片 / 头像 / 重试映射未变化。旧 schema 8 服务不能直接读取 schema 9，回退不能只换旧镜像或覆盖备份来丢弃后续写入。
- 容器资源上限不变：视频同时仅处理 1 个，最长解码 45 秒，临时输入 / 输出总计约 40 MiB，保留现有 64 MiB tmpfs。不要绕过损坏文件、类型、时长、画幅或存储限额校验。
- 两台真实账号验证：POI 与 Reel 图片 / 视频混排；横屏 / 竖屏和音频；弱网排队重试不重复；私人 GET / HEAD / Range 不外泄；公开 / 改私密 / 删除即时影响访问；50 MiB 满额提示能恢复。iPhone 验收由用户操作，不自动操作其手机。

## 视频断点续传更新（2026-10-21 已部署 schema 10）

2026-10-21 13:20（America/Los_Angeles），现有 EC2 切换到新版，公网 HTTPS 健康与未认证 PATCH 拦截通过。159 项目标 Linux ARM64 隔离测试通过，包含真实视频解码、分段断线/重启恢复、取消竞态、权限和配额。实际 S3 加密备份取回、认证恢复、迁移副本及正式库对比均通过，22 张原有表全部内容一致（1 用户、9 记录、8 媒体）。兼容的 Release 客户端已覆盖安装到 iPhone，未卸载、启动或操作手机界面。详细命令与安装凭证见 `deploy/aws/deployed-resources.json` 的 `resumableVideoRelease`。

- 使用同一 EC2 / SQLite / 加密数据盘；新增上传会话与分段表，不增加云服务、机器规格或 50 MiB / 用户额度。会话预占空间，取消与 7 天未活动过期清理；分段不是公开媒体。轻量完成 receipt 保留，实际 staging bytes 完成即删除。
- schema 9→10 是增量建表，不重写既有记录。部署前仍须完成加密备份及恢复、schema 9 完整旧数据比对、真实分段上传/断线恢复、完成校验/播放权限和取消竞态测试；更新后才安装使用新协议的客户端。旧 `/v1/media` 接口兼容，但旧 schema 9 二进制拒绝 schema 10，不可直接 image-only 回退或覆盖后续用户写入。
- 资源清单已更新为实际 schema 10 发布结果；没有新增服务、机器升级、密钥变更或额度增加。首次备份因只读挂载不能创建 SQLite 临时文件而中止，旧服务自动恢复；改用允许 SQLite 辅助文件的挂载后重新备份、恢复和比对通过，未跳过检查。临时恢复库及 S3 源码包已删除，保留加密备份。
- 暂时处理失败返回可重试 503，保留已传字节；格式和内容校验仍保留，不因改善弱网体验而放宽。真实 iPhone 的 Wi-Fi / 蜂窝切换、锁屏及再次进入续传由用户验收。

## 视频时长误判修复（2026-10-21 已部署，schema 10 不变）

2026-10-21 13:57（America/Los_Angeles）已原地更新。原视频上传字节完整、SHA-256 一致；失败来自 Apple edit-list 与 FFmpeg remux 的时长表示差异，并非证明用户原视频损坏。修复保留展示时间线及每个音视频 packet，提高 MP4 时钟精度；仅接受有上限的源时钟舍入误差（最多 2ms + 1µs），输入大小、时长、分辨率、完整解码和配额检查仍保留。

- 完整本地后端测试 225 项、生产 ARM64 运行时测试 162 项通过；生产待处理视频在同资源上限的只读隔离验证中通过，未下载或代替用户发布该内容。最初误把依赖 Python/部署文件的主机工具测试放进最小运行镜像，随后按运行时范围重跑通过；主机工具在本地完整测试中通过。
- 切换前完成实际 S3 加密备份取回及认证恢复，schema 10 全部 24 张表逐值一致，包括 1 个上传会话及 15 个已传分段。公网 HTTPS 与容器健康正常，资源、额度及密钥不变。回退镜像保留为 `maptalk-backend:schema10-pre-timing`，不需也不应覆盖已有数据库。
- 客户端本地 MyMap 预览与上传分离：点卡片打开原有内容，不弹上传故障框；失败记录只保留独立的小型重试入口。未获服务端确认的本地预览不冒充已公开 feed。旧版已标记失败的任务需重试一次，继续原任务而非要求重选视频。
- 14:12 已覆盖安装签名 Release 到原 iPhone，未卸载、启动或操作手机界面。198 单元测试及 6 项 UI 回归通过，额外重复视频中部下拉 3 次通过；短内容不再由内部滚动抢走下拉手势，交互缩放保留同一个播放器。真机发布、断网及锁屏恢复仍由用户验收；测试和安装凭证见资源清单。

## 72 小时动态规则更新（2026-10-22 后端已部署，客户端验收中）

2026-10-22 00:05（America/Los_Angeles；UTC `2026-10-22T07:05:23Z`）已在原 EC2 切换成功，schema 10 不变。公开 Reel／POI 的动态窗口统一为 72 小时：Reel 到期退出主地图，POI 到期退出动态但保留历史足迹数据；不会因到期删除个人 MyMap。真正删除和旧版仅隐藏归档是不同操作，不把历史归档隐藏误记为服务端删帖。

- 226 项本机后端测试、79 项目标 Linux ARM64 隔离测试通过。部署 SSM 为 `c129b58f-e903-4a9e-b2bf-ff6d1d2101ed`，镜像 tag 为 `maptalk-backend:freshness-72h-20261021`，运行别名为 `maptalk-backend:local`；完整镜像与源码 SHA-256 见 [资源清单](deploy/aws/deployed-resources.json) 的 `freshness72HourRelease`。
- 切换前实际 S3 备份取回、密文逐字节比对及认证恢复通过（SSM `cf0a0246-29a5-48c2-8309-ec982c0ca615`）。`maptalk/backups/pre-freshness-20261022T0700.mtbak` 为 19,431,460 字节，SSE-S3 `AES256`；恢复副本 schema 10 的全部 24 张表与快照一致，计数为 1 用户、15 记录、13 媒体、1 上传会话、0 分段。没有覆盖在线库。
- 最终容器 healthy、未 OOM、重启次数 0；HTTPS 健康 200，未认证 feed／map 均为 401。仍为 1 CPU／768 MiB 容器限制，无新增云服务、资源升级、密钥更换或每用户额度增加。回退镜像 `maptalk-backend:pre-freshness-20261022` 保留；只回退代码，不用旧快照覆盖后续写入。
- **临时清理待用户批准：** 自动清理被审批拒绝，已请求明确批准但尚无回复。S3 `maptalk/deploy/freshness-72h-20261021/source.tgz` 非敏感源码包，以及服务器 `/srv/maptalk/backups/freshness-verify-20261022` 的明文恢复库／快照仍保留（目录 0700、文件 0600）。正式加密备份和回退镜像保留，不属于临时清理范围。
- 客户端 216 项单元测试通过，最终地图控件 UI 在原模拟器连续通过 3 次（0 失败），包含足迹标记不遮挡定位／发布按钮的检查；结果为 `/private/tmp/maptalk-controls-final-repeat.xcresult`，没有新建模拟器。最终 iPhone Release 构建与签名校验通过（`/private/tmp/maptalk-history-final-release-build.log`），产物连接 `https://api.maptalkapp.com`。2026-10-22 13:36（America/Los_Angeles）经用户要求，已覆盖安装到连接的 iPhone 15 Pro，devicectl 返回安装成功（bundle ID `com.chengsi.maptalk`）；未卸载、未启动 App 或操作手机界面，真机体验仍待用户验收。

## 文案编辑与机场地标（2026-10-22 已部署 schema 11）

现有 EC2 已更新，`2026-10-22T21:19:36Z` 独立复查通过：schema 11、完整性正常、外键错误 0、容器 healthy、公网 HTTPS health 200／未登录 feed 401。原资源、密钥及 50 MiB 用户额度不变。新增本人 Reel 文案编辑；机场目录支持 2 km 中心距离，普通地点仍 150 m，发布坐标仍为本人 GPS。已有但未分类的地点不按名称猜测升级。

- 237 项本机后端、88 项目标 Linux ARM64 隔离测试通过。切换前关闭公开入口并停止写入，做最新加密备份、S3 上传／取回／密文比对／认证恢复；恢复与正式迁移均核对全部 24 张表，原有 1 用户、16 记录、14 媒体、1 上传会话、0 分段保持一致。
- 第一次切换因检查脚本的 Node fetch 未真正发送指定 Host 而安全回退。改用先行验证过的 node:http 请求后切换成功；第二次命令仅在切换后的摘要打印遇到报告权限错误，独立只读检查确认新版正常及保存的校验报告通过。没有放宽 origin／鉴权保护。凭证见资源清单 captionAirportRelease。
- 旧 schema 10 镜像不能读取 schema 11。现在已恢复公开写入，不可恢复旧快照覆盖新增内容。正式加密备份和回退镜像保留；本轮临时验证目录以 0700 权限保护并暂存，之前 freshness 临时清理仍待明确批准。
- 客户端空文案隐藏、本人 Reel 文案编辑／删帖、POI 删除本人单次打卡、重复访问先看最新，以及发布面板内拍照／录像已完成。233 项单元、4 项 UI 回归、1 次截图复测通过；iPhone Release 构建和签名校验通过，**已于 2026-10-22 14:27（America/Los_Angeles）按用户要求覆盖安装到 iPhone 15 Pro**，安装序号 7340；未卸载、启动或操作手机界面。相册取消测试修正了系统 Photos 首次加载时坐标尚未稳定的等待方式，没有绕过实际点击及关闭验证。
- 真机取景、录音和机场候选仍待用户验收。固定 SeaTac 测试点的 macOS MapKit 实查返回 MKErrorDomain code 1，不能宣称真实机场候选已验证，也不能据此认定 Apple 没有该机场数据。

## POI 搜索、文字评论和动态时效（2026-10-23，后端已部署 schema 12）

用户批准更新及重新登录后，现有 EC2 于 `2026-10-23T21:07:34Z` 完成 schema 11→12，21:08 独立复查通过：schema 12、integrity ok、0 外键错误、容器 healthy、公网 HTTPS health 正常、未登录 feed/map/comments 均 401。未增加服务、资源、额度或更换密钥。

切换前完成目标 ARM64 隔离测试、加密备份实际 S3 上传／取回／密文比对／认证恢复及独立迁移演练；关闭公开入口后重新取得最新备份，正式迁移再次核对全部原有 24 张表。1 用户、20 记录、17 媒体、6 上传会话、0 分段完全一致。`scripts/verify-schema12.mjs` 只允许新增评论表及三个索引。最终加密对象为 `maptalk/backups/pre-comments-poi-final-20261023.mtbak`，40,312,868 字节、SSE-S3 AES256。切换命令 `8d56467f-5d51-4149-9888-15b1ddc00c83`、独立验证命令 `18c19be2-bd2b-46ed-8218-f283c816bd18` 均 Success。

- 评论只发文字，不创建打卡、不要求定位，也不刷新帖子 72 小时动态时间。私有、删除、拉黑、撤销内测资格和审核状态仍参与权限判断；客户端弱网重试沿用同一评论 ID。
- 客户端附近选择器取消 6／8 条截断，增加真正的 Apple 地名搜索；只修正有匹配目录来源的分类展示，不重写已有地点及发布坐标。2026-10-23 固定 SeaTac 坐标的 Apple 实查成功：附近机场及地名查询均返回 Seattle-Tacoma International Airport，目录中心距查询点约 898 米。不是所有区域覆盖保证，真机定位仍待用户验收。
- 客户端对旧缓存增加 72 小时截止；过期 POI 留在历史足迹层，不再因为被选中恢复大动态标记。公开卡片使用发布时间，私有归档保留记录时间。左右翻页及地图飞行路径不做改动。
- 266 项本机后端、117 项目标 ARM64、266 项客户端单元、7 项界面回归及 2 项搜索视觉复测通过。单元结果 `/private/tmp/maptalk-poi-comments-units-final-20261023.xcresult`，界面结果 `/private/tmp/maptalk-poi-comments-final-20261023.xcresult`（该轮界面全通过，旧过期夹具引起的两个单元失败已修正并独立全量复测），视觉结果 `/private/tmp/maptalk-poi-search-visual-final-20261023.xcresult`。复用原模拟器。未操作手机界面，真机体验待用户验收。
- 回退镜像 `maptalk-backend:pre-comments-poi-20261023` 保留；schema 11 镜像不能直接读取 schema 12。恢复公开流量后不可覆盖旧快照丢弃新评论／删除记录，需前向修复或兼容 schema 12 的回退版本。本轮验证副本暂存于服务器 `comments-poi-verify-20261023`／`comments-poi-cutover-20261023`（目录 0700、文件 0600）；不与正式加密备份混淆，不在本轮擅自清理此前待批准的验证副本。
- 此前签名阻塞已确认是旧 Apple Development 证书过期，且 Xcode 没有登录开发者账号。用户批准替换开发签名证书并完成账号登录后，新身份可用，iPhone Release 构建及 `codesign --verify --deep --strict` 均通过（`/private/tmp/maptalk-renewed-device-release-20261023.log`）；Team、Bundle ID、Apple 登录 entitlement 和 `https://api.maptalkapp.com` 均核对一致。**2026-10-23 11:27（Pacific/Honolulu）已按用户要求覆盖安装到 iPhone 15 Pro**，安装序号 7476，回执 `/private/tmp/maptalk-comments-poi-device-install-20261023.json` 返回 success，随后按 Bundle ID 复查已安装。未卸载、未启动或操作手机界面；不清理本地数据／待上传内容。没有修改工程签名配置、撤销证书或更换服务端 Apple 登录密钥。

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
- [ ] A 改私密／真正删帖，B 刷新后无法再读，断网重进地图也不复现；区分旧版仅隐藏归档的 Remove 与服务端删除。
- [ ] 公开动态在 72 小时后退出 feed；Reel 退出主地图，POI 仍可作为历史足迹查看；MyMap 原记录保留。
- [ ] 举报可查、屏蔽双向生效；撤销成员后其现有会话被拒绝。
- [ ] Apple 用户删号成功；Apple 撤销接口失败时不会谎报删除成功，能够重试。
- [ ] 杀掉 App、断网重试、上传重复请求和重新部署不会丢数据或产生重复帖子。
- [ ] 加密备份有成功文件，完成异地复制和新路径恢复演练。
- [ ] 隐私／支持页面可访问；有人每天处理审核和举报。
- [ ] 两台真机及计划邀请地区的网络可用，再制作 TestFlight 包。

这些勾选是上线门槛，不是本地自动化测试会自动完成的事项。
