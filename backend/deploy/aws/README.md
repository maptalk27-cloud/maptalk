# AWS 亲友版部署与验收

2026-10-20，**后端已在现有 EC2 上运行，`https://api.maptalkapp.com/health` 已通过公开 DNS、可信 HTTPS 和健康检查**。这不代表已完成 Apple 真机登录或可以邀请亲友：真实授权／删号、两台真机隐私验收、隐私与支持页面仍未完成。App UI 和现有发布模型不变。

用户已明确批准非敏感代码经自己的私有 S3 部署，并将现有 Apple 登录私钥、Apple token 加密 key 和备份加密 key 分别存入 `us-east-2` 的三个 Secrets Manager secret；不更换密钥，不把 `secrets.tar` 上传到 S3。实际资源和验证记录见 [deployed-resources.json](deployed-resources.json)。主机及相关资源已开始计费，当前仍为 Free Plan；正常基础估算约 $20.05/月，按已确认的 $25/月预算规划，不依赖赠送额度，也不是硬封顶。不要重复创建另一台主机。升级 Paid Plan 或扩大资源范围仍须单独确认。

当前范围：10–20 位受邀用户、Apple 登录、照片、短视频、POI／Reel、MyMap。2026-10-21 已将现有主机升级到包含 FFmpeg 的 schema 9，未新增服务、扩容或提高每用户 50 MiB 媒体额度。真实聊天／好友／通知及 Collection 云同步仍不在上线范围内。完整边界和两台真机验收见 [部署说明](../../DEPLOYMENT.md)。

最新视频发布验证：210 项本机测试、87 项目标 ARM64 隔离测试通过；60 秒 / 720p / 60fps 合成视频在 1 CPU / 768 MiB / 64 MiB tmpfs 限制下处理用时 9.4 秒。网关等待调整为 120 秒以覆盖有限时的视频校验。实际加密备份取回恢复、完整表内容迁移校验和 HTTPS 健康检查通过，现有用户及帖子未改变。视频真机发布由用户验收；详细结果见 [deployed-resources.json](deployed-resources.json) 的 `videoRelease`，下文早期部署记录保留作为历史。

## 预算

2026-10-19 使用 AWS Pricing API 核对的 `us-east-2` 正常按需价格，**不扣任何赠送额度或临时优惠**：

| 项目 | 配置／单价 | 31 天示例 |
| --- | --- | ---: |
| EC2 Linux | 一台 `t4g.small`，$0.0168/小时 × 744 小时 | $12.50 |
| gp3 EBS | 系统 10 GiB + 数据 20 GiB，$0.08/GiB·月 | $2.40 |
| 公网 IPv4 | 一个，$0.005/小时 × 744 小时 | $3.72 |
| S3 加密备份 | 每份暂按 1.25 GiB，预留 8 份，$0.023/GiB·月 | $0.23 |
| Secrets Manager | 三个 secret，$0.40/个·月 | $1.20 |
| 小计 | 未含请求、税、域名、超额流出 | **$20.05/月** |

730 小时月份小计约 $19.74。Secrets Manager 增量费用已于 2026-10-20 确认；调用另计 $0.05/万次，例如每月 1,000 次为 $0.005。来源：[EC2](https://aws.amazon.com/ec2/pricing/on-demand/)、[EBS](https://aws.amazon.com/ebs/pricing/)、[IPv4](https://aws.amazon.com/vpc/pricing/)、[S3](https://aws.amazon.com/s3/pricing/)、[Secrets Manager](https://aws.amazon.com/secrets-manager/pricing/)。

用户已接受 **约 $25/月的规划预算**，不是硬封顶；不含税、域名及超额流出。批准范围为下述单台服务器、30 GiB 加密 gp3、一个公网 IPv4、私有 S3 加密备份和三个 Secrets Manager secret。超出该范围或报价明显变化时重新确认，不默认升级计划。

- 每用户照片额度 50 MiB；20 位用户合计不足 1 GiB。1.25 GiB 数据库是假设，包含一定余量，不是数据库硬限制。本地数据库、7 份备份、WAL 和创建备份的明文／密文临时文件都占数据盘。
- S3 PUT 类请求 $0.005/千次、GET $0.0004/千次；备份分为多个 8 MiB 分片，不是每天一个请求。同 Region EC2↔S3 传输免费。
- 互联网流出前 100 GB/月是 AWS 多服务共享额度。若全部可用，总流出 200 GB 时额外约 $9，500 GB 时额外约 $36，不是无限流量。
- `t4g` 使用 **Standard** CPU credits，避免 Unlimited 积分附加费；积分耗尽会降速，需实测照片处理。gp3 只用基线性能，S3 用 SSE-S3。
- 不含域名、付费 DNS、税、额外快照／存储／IP，以及其他服务。没有 NAT Gateway、负载均衡器、RDS、付费 CDN、付费日志平台或自管 KMS 密钥；加服务须重新报价。停止实例后磁盘等仍可能收费。
- AWS Budgets 通知有延迟，**不是硬限额**。AWS Settings 的 spend limit 是另一种会暂停项目的机制，不擅自升级 Paid Plan 或替用户设置。[预算延迟](https://docs.aws.amazon.com/help-panel/cost-management/latest/console/hp-budget-details.html)、[spend limit](https://docs.aws.amazon.com/accounts/latest/reference/create-spend-limit.html)。

2026-10-20 最新只读检查为 Free Plan / ACTIVE，剩余 $100 credits；额度状态不是长期价格保证，也不代表资源不计费。在 **AWS Settings → Billing** 查看计划和额度；在 **View all projects → Overview → Additional Info → Region** 确认 `us-east-2`。

## 已批准并创建的部署资源范围

- 一台 Linux ARM64 EC2 `t4g.small`，单实例单进程 SQLite，不做多副本。
- 10 GiB 系统盘、20 GiB 持久数据盘，均加密 gp3。数据盘已挂到 `/srv/maptalk`，Docker 数据及容器存储同在该盘；启动检查核对挂载 UUID，不能误写系统盘。保留数据盘，不随实例误删。
- 一个稳定公网 IPv4，域名 DNS 指向它。仅公开 TCP 80/443，不公开 8787、数据库或 SSH；运维用 Systems Manager。
- 实例服务角色提供短期凭据，备份权限限制到一个 S3 bucket 的指定前缀。不是复制开发者完整权限，也不是给 team member 分配角色。IMDSv2 required、metadata response hop limit **2**；运行中的实例已成功上传加密备份。
- `us-east-2` 内的私有 S3 通用 bucket：Block Public Access 全开、ACL disabled、TLS-only、SSE-S3。备份前缀只收已 AES-GCM 加密的 `.mtbak`，不是公开照片 bucket。独立的临时部署前缀仅用于获准的非敏感代码，不存 Apple 私钥或加密 key。
- 备份前缀配置到期 7 天、未完成 multipart 1 天清理。若启用版本控制，需处理非当前版本的保留和费用。Lifecycle 不是精确计时器，8 份是容量预留，不是强制上限。
- 三个 Secrets Manager secret 使用 AWS-managed encryption，不新增付费 customer-managed KMS key，不自动轮换、不跨 Region 复制。宿主机按最小范围读取，密钥不写入镜像、源码、SSM 参数或日志。

应用不会创建资源或修改权限／生命周期；这些是部署时必须验证的前提。[S3 安全与角色凭据](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)。可选 CloudTrail data events、S3 access logs 等审计／监控应评估成本后启用，不暗中增加付费服务。

## 已确认域名与接线顺序

- `maptalkapp.com` 由用户注册，公共 NS 为 `corey.ns.cloudflare.com` 和 `magnolia.ns.cloudflare.com`。继续在 Cloudflare 管理 DNS，不新增 Route 53 hosted zone，也不修改无关的根域名、邮箱或其他记录。
- Cloudflare 仅新增 `api` 的 A 记录，指向固定 IPv4 `3.146.199.64`，DNS-only；没有修改无关记录、增加 AAAA 或新建 Route 53 hosted zone。公开 DNS 查询已核实。
- Caddy 已直接提供公开可信的 HTTPS；`https://api.maptalkapp.com/health` 返回 HTTP 200、`mode: private-beta`、`apiVersion: 1`。没有以关闭证书验证代替 TLS 验收。
- DNS/TLS/health 门槛通过后，已创建被 Git 忽略的 `Config/Backend.local.xcconfig`，指向最终 HTTPS API。签名构建、真机安装和启动已完成；真实 Apple 授权与功能验收仍待完成，健康检查不是 Apple 登录证明。
- 隐私和支持页面尚未实现，不填写假链接或虚构邮箱；这仍是邀请用户前的门槛。

## 配置与运行

现有主机已安装 Docker Engine 和 Compose plugin，并完成目标 Linux ARM64 镜像真实构建。`sharp` 的 Linux native 依赖、SQLite 和 JPEG 编码均已通过运行检查；没有复制 Mac 的 `node_modules`。

- [compose.env.example](compose.env.example)：域名和宿主机绝对路径。
- [runtime.env.example](runtime.env.example)：Apple IDs、两把独立加密 key、S3 bucket。

现有三把密钥分别保存在 Secrets Manager；安装器将需要的运行配置放到宿主机 `/etc/maptalk`，runtime env 权限 0600，目录 0700。`.p8` 只读挂载，须 UID 1000 可读，例如 owner 1000、0400；Compose 不会替文件 secret 重映射权限。重复安装必须复用现有 key，不能发送到聊天、提交 Git 或重新部署时替换。

四个持久目录预先创建并授予 UID 1000 读写权限。恢复的数据库及 WAL／SHM 也须属于 UID 1000。`create_host_path: false` 拒绝缺失目录，但不能证明目录位于持久盘。API 和 Caddy 都以非 root、只读系统目录运行，限制内存、进程和日志；仅 Caddy 发布 80/443。

主机的配置、构建、preflight 和运行入口如下；本轮实际验证结果见文末记录。重新部署前仍须保留数据及既有密钥：

```sh
docker compose --env-file /etc/maptalk/compose.env -f /opt/maptalk/backend/deploy/aws/compose.yaml config --quiet
docker compose --env-file /etc/maptalk/compose.env -f /opt/maptalk/backend/deploy/aws/compose.yaml build
docker compose --env-file /etc/maptalk/compose.env -f /opt/maptalk/backend/deploy/aws/compose.yaml run --rm --no-deps api node scripts/deployment-preflight.mjs
docker compose --env-file /etc/maptalk/compose.env -f /opt/maptalk/backend/deploy/aws/compose.yaml up -d
```

用 `config --quiet`，不要将展开 secrets 的完整配置贴到日志或聊天。首次使用空 beta 库，不上传本机 Demo 库。

Preflight 只检查本机配置、Apple 私钥格式、两把独立 key、目录和 Region，不访问 AWS、不创建数据库；不能验证域名归属、真实 Apple 授权、S3 权限或预算。Health 只证明 API 返回 `private-beta`。

## 备份与恢复

AWS 模式要求 S3 配置，缺失时拒绝启动，不悄悄退回本机备份。SQLite 在线快照先 AES-GCM 加密，再上传到 `maptalk/backups/YYYY-MM-DD.mtbak`。每个数据库／部署必须使用独占前缀，不能让两个不同数据库竞争同一个日键。本地保留 7 份；成功记录和日唯一对象键减少重复上传。上传失败保留本地文件并报告失败，默认每小时最多重试一次，冷却记录跨重启保存。

上传重试／超时有上限，每次一个 8 MiB 分片。取消或失败时尝试清理 multipart，但网络断开时仍需 bucket 生命周期兜底。

邀请前必须实测实例角色上传，再取回 `.mtbak` 到私有路径，执行 `encrypted-backup.mjs restore` 到**全新数据库路径**。校验用户、私密照片和删号处理；不能仅凭 S3 存在文件就认为可恢复。密钥与服务器、备份分开保管。

2026-10-20 已完成实际 S3 文件下载、认证解密与新临时数据库的 `PRAGMA integrity_check`。该快照来自首次启动的空 beta 库，用户／记录／媒体均为 0；在线数据库未替换，临时恢复文件已清理。它验证了真实传输、密钥和恢复机制，**尚不证明真实用户照片、隐私及删号后的业务数据恢复正确**。

磁盘达到 70% 或备份失败应先处理，再继续邀请；核对最近成功备份时间、S3 日期、生命周期和空间。目前没有云告警自动化，日志不等于已发通知。恢复旧备份前必须补做恢复点之后的删号／撤回，不能把旧内容直接重新公开。

## 邀请前门槛

- [x] 用户接受约 $25/月规划预算及上述资源范围，授权开始部署（2026-10-19）。
- [x] 用户自行购买 `maptalkapp.com` 并授权使用（2026-10-19）；没有代购或额外域名费用。
- [x] 用户批准非敏感代码经私有 S3 部署、现有三把密钥存入 Secrets Manager 及约 $1.20/月增量费用（2026-10-20）。
- [x] `api.maptalkapp.com` DNS、HTTPS 和 API 健康检查通过；未升级 Paid Plan。
- [x] Linux ARM64 镜像真实构建运行，`sharp`、SQLite、Caddy 和 TLS 通过。
- [x] 实际 EC2 重启后原数据盘、Docker、容器自动恢复和 HTTPS 健康检查通过；空库完整性及内容计数保持一致。
- [ ] 最终 HTTPS 地址下真实 Apple 登录和账号删除通过。
- [x] 实例角色上传、真实 S3 下载、认证解密和新临时空库完整性检查通过；未替换在线数据库。
- [ ] 用真实测试账号和私密照片完成恢复／权限／删号验收，费用／备份／审核负责人明确。
- [ ] 两台真机通过 [完整验收](../../DEPLOYMENT.md#发邀请前验收)，隐私和支持页面完成。
- [ ] 目标地区真实网络通过；Ohio 部署不代表已解决中国大陆可达性。

不再测试时先问用户资源保留／清理选择并解释残余费用，再执行；不自动删库、删 bucket 或销毁密钥。

## 最新部署验证记录（2026-10-20）

- 已使用现有 Apple Development 身份签名并安装到用户连接的 iPhone 15 Pro（iOS 26.6.2），`devicectl` 确认安装与启动成功。系统签名验证通过，签名中保留 `com.apple.developer.applesignin = Default`，Team / Bundle 与后端配置一致，安装包内 API 为 `https://api.maptalkapp.com`。没有卸载 App、清除数据、修改 UI 或启动模拟器；真实 Apple 授权及后续功能验收仍需用户在手机上操作。
- 本机完整测试：**177 项通过**。早先 v2 包完整性验证为 macOS ARM64 / Node 24.10 下 147 项通过；不能用本机结果代替目标平台验证。
- 实际部署的非敏感代码包为 v4，108,829 字节，SHA-256 `0ef3a53ab042bc9b5711bfe2155053ffbb41ce9f18a39aa3098bf1c576c6655e`；密钥没有随源码包或 `secrets.tar` 进入 S3。
- 主机 bootstrap 成功（SSM `dd07aa37-3c55-4a10-8529-998ade0ab596`）：AL2023 `aarch64`、数据盘 UUID `c21b1a3e-3efb-4419-b680-6a0e68b10863` 挂到 `/srv/maptalk`，Docker root 同在数据盘；加密磁盘、数据盘保留和 Standard CPU credits 已核实。
- 三个 Secrets Manager secret 已在获准的 `us-east-2` 创建；安装成功（SSM `69db4781-93d1-411f-a224-0857611deca4`）。安装过程修复了 PEM 末尾换行处理，没有创建、轮换或替换 Apple 密钥及两把加密 key。
- Linux ARM64 镜像构建成功（SSM `3bbe7776-188c-4988-afcb-d3bc1f4596da`）；运行版本为 Node 24.22.0、libvips 8.18.7，原生 SQLite 和 JPEG smoke test 成功（SSM `e1fd250a-b4ee-4d27-99b0-c335eb49b021`）。
- **114 项核心测试在实际 Linux ARM64 生产镜像中通过**（SSM `11e60dfc-0172-49fe-a256-f58da77c21ba`）：使用临时数据、只读测试文件和隔离网络，未挂载真实密钥。覆盖照片处理、权限、持久化、加密恢复及模拟认证／S3；不代表真实 Apple 登录或真实云端备份恢复已通过。
- API 已 healthy，Caddy 已运行；Cloudflare `api` A 记录、公开 DNS、正常证书验证下的 HTTPS `/health` 均通过。
- 运行中的实例角色已上传 `maptalk/backups/2026-10-20.mtbak`，249,892 字节。实际 S3 文件取回后，用现有 key 认证解密到全新临时数据库，完整性检查为 `ok`，用户／记录／媒体均为 0；在线库未改动，临时文件已移除。这是初始空库演练，不是带真实用户照片的恢复验收。
- 已执行实际 EC2 reboot，重启时间为 `2026-10-20 20:44:20 UTC`。SSM `e63c8c0e-45f3-447d-a52b-67c8621b5b5c` 验证启动约 36 秒后原数据盘 UUID、Docker root 正确，两个容器自动启动，容器健康检查及公开 HTTPS 再次通过，数据库完整性和空库计数不变。S3 备份 ETag／时间未变，没有因重启重复上传。
- 两个临时 S3 部署对象已删除，`MapTalkTemporaryDeploymentRead` 已移除；bucket 仅剩上述备份对象。角色 inline policy 仅保留 `MapTalkEncryptedBackups` 和 `MapTalkRuntimeSecretsRead`，SSM managed policy 仍用于运维。
- 未认证访问 `/v1/me` 和 `/v1/feed` 均返回 401；provider 状态仅 Apple available，Google／WeChat 为 false，与本轮仅接入 Apple 的范围一致。这不是实际 Apple 授权往返验证。
- 已启用本机 Git 忽略的 iOS HTTPS endpoint 配置。Xcode 26.0.1（17A400）下，`maptalk` scheme / Debug / generic iOS ARM64 / `CODE_SIGNING_ALLOWED=NO` 构建成功（exit 0）；产物 `Info.plist` 的 `MapTalkBackendURL` 为 `https://api.maptalkapp.com`，Bundle ID 为 `com.chengsi.maptalk`，最低 iOS 为 26.0。这是未签名编译验证，不是安装、真机 Apple 登录、邀请测试者或 App Store 提交。
- iOS 当前签名构建产物：`/private/tmp/maptalk-ios-verify.FSjiHT/DerivedData/Build/Products/Debug-iphoneos/maptalk.app`；签名构建结果：`/private/tmp/maptalk-ios-verify.FSjiHT/Signed-device-20261020.xcresult`。先前的未签名验证结果另保存在 `Build-retry.xcresult`。当前版本仅安装到机主的连接设备，未向其他测试者分发或提交 App Store。
- `2026-10-20 20:46 UTC` 另已验证 HTTP 返回 308 并跳转 HTTPS。
- 真实 Apple 登录和账号删除、两台真机验收、隐私／支持页面以及目标地区网络仍未通过；后端健康不等于 App 已完成上线验收。

### 上一轮本地验证（2026-10-19）

- `npm test`：123 项通过，0 失败／跳过；S3 使用真实 SDK 命令和假服务端，未调用云 API。
- `npm run demo`：本地双账号 HTTP 发布、私密隔离、重启和备份恢复通过。
- Compose 配置离线解析通过；Docker daemon 未运行，**镜像 build/run、Linux ARM64、Caddy TLS 和真实 S3 恢复均未验收**。
- AWS SDK 精确锁定 `3.1152.0`。本机默认 npm 的企业证书验证失败后，通过正常 TLS 的 Yarn 公共镜像安装，没有关闭证书校验或修改全局 npm 配置；lockfile 保留标准 npm 下载地址和完整性校验。
