# MapTalk 后端

这一版连接现有 iOS 界面：账号登录、照片上传、POI / Reel 发布、MyMap、公开主页和地图读取。真实账号与原来的 mock 演示分开，不混用记录。

默认是仅本机开发模式；另有显式开启的封闭内测模式。使用 Node 24.10–24.x 内置 HTTP、SQLite 和测试工具，Sharp 用于真实图片解码、压缩和去除元数据；FFmpeg / FFprobe 验证短视频并移除非必要元数据。亲友版的部署、账号配置、备份及真机验收按 [部署说明](DEPLOYMENT.md) 进行；代码完成不等于服务已经部署。

AWS 准备代码和正常月费估算见 [AWS 亲友版](deploy/aws/README.md)。当前只准备容器、加密备份和启动预检；未经预算与部署确认，不创建云资源。

## 运行

运行视频上传及完整测试前，`PATH` 必须包含 `ffmpeg` 和 `ffprobe`（部署 Docker 镜像已经声明这两个依赖；本机需自行安装）。测试使用真正编码的合成视频，不替换或跳过解码器。在项目的 `backend` 目录执行：

```sh
npm ci
npm test
npm run demo
npm start
```

`demo` 自动建立两个测试账号，上传照片，验证同地点的私密记录不会随另一条公开记录泄露，然后重启服务并从独立备份恢复。临时数据会清理，不修改默认数据库。

`start` 在 `http://127.0.0.1:8787` 启动。数据库默认保存到 `backend/data/maptalk.sqlite`，重启保留，没有预设账号或帖子。可用 `PORT` 改端口、`MAPTALK_DATABASE` 指定数据库路径。Node 的 SQLite experimental warning 是当前运行时提示，不是测试失败。

默认服务监听本机地址，并限制 Host / Origin；不会开放给局域网手机或公网。仅在显式配置 beta、HTTPS origin、真实登录平台、持久数据库和备份密钥后，才允许绑定其他地址。不要将本机测试库或旧媒体直接迁到 beta。

## 在现有模拟器中使用

在 Xcode 的 Debug Scheme → Run → Arguments 加入 `--local-backend`，运行原来的模拟器即可，不用新建或重启设备。登录页提供 Apple、Google、微信和独立的 Demo 入口。

现在要体验原 App：点 **Use demo** 即可进入，不需要用户名或密码。这个 Debug 专用入口不需要后端或平台账号，进入现有内存演示数据；不写真实账号的 Keychain，也不向后端发布。Me → Settings → Exit demo 可返回登录页。Release 不包含该入口。

真实账号登录需要先启动本机后端，并完成对应平台配置。没有配置的平台会明确提示原因，不会自动变成 mock 登录。

### 平台配置

Apple 登录需要开发者账号中的 App ID 启用 Sign in with Apple，并使用包含该能力的签名配置。项目已声明对应 entitlement；开发者注册问题尚未解决时，不能视为真实 Apple 登录已验证。启动本机服务时配置与 iOS Bundle ID 完全一致的 audience：

```sh
MAPTALK_APPLE_CLIENT_ID=com.chengsi.maptalk npm start
```

Apple 系统登录先获取服务端一次性 challenge，App 原样设置 `request.nonce`，再将 Apple identity token 交给服务端验证。服务端校验签名、issuer、audience、有效期和 nonce。

Google 和微信的 iOS 官方 SDK 已链接。将 `Config/AuthProviders.local.xcconfig.example` 复制为同目录的 `AuthProviders.local.xcconfig`，仅填写公开 App ID 和回调配置；这个本地文件不进 Git。不要把任何 client secret 或 AppSecret 放入 iOS 工程。

| 平台 | iOS 本地配置 | 仅后端环境变量 |
| --- | --- | --- |
| Apple | App ID 开启 Sign in with Apple，匹配签名配置 | `MAPTALK_APPLE_CLIENT_ID=com.chengsi.maptalk` |
| Google | `MAPTALK_GOOGLE_IOS_CLIENT_ID`、`MAPTALK_GOOGLE_SERVER_CLIENT_ID`、`MAPTALK_GOOGLE_REVERSED_CLIENT_ID` | 同名的两个 client ID，加 `MAPTALK_GOOGLE_CLIENT_SECRET` |
| 微信 | `MAPTALK_WECHAT_APP_ID`、callback scheme、HTTPS Universal Link、Associated Domain | `MAPTALK_WECHAT_APP_ID`、`MAPTALK_WECHAT_APP_SECRET` |

Google 需要同一项目下的 iOS OAuth client 和 Web/server OAuth client。iOS SDK 返回一次性 `serverAuthCode`，后端兑换并独立校验 Google ID token，不接受客户端自行声明的用户身份。[Google 官方接入说明](https://developers.google.com/identity/sign-in/ios/start-integrating)、[服务端授权说明](https://developers.google.com/identity/sign-in/ios/offline-access)。

微信需要开放平台审核通过的移动应用和登录权限；真机须安装微信。Universal Link 的域名由你控制，并提供匹配 App ID、Team ID 和路径的 `apple-app-site-association`。完成签名能力配置后，再按本地模板启用 `maptalk-social.entitlements`。SDK 回调与当前 state 匹配后，后端用 secret 兑换 code，以 `appid:openid` 识别用户。[微信 iOS 接入指南](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Access_Guide/iOS.html)、[移动登录指南](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/WeChat_Login/Development_Guide.html)。

后端变量可放到不进 Git 的 `backend/.env`，用 Node 24 的 `node --env-file=.env src/main.mjs` 启动。只填写已经申请的平台，未申请的变量不要设置。真实 Apple、Google、微信授权均需完成上述注册及配置后再用实际账号验证；当前代码与测试通过不等于真实授权已完成。当前客户端和服务仍仅连接本机；微信真机端到端验证还需要后续部署可访问的 HTTPS 后端，不能把手机上的 `127.0.0.1` 当作 Mac。

同一 provider 的已验证身份对应稳定的 MapTalk 账号。不同 provider 不会因相同邮箱、昵称或 UnionID 自动合并；账号绑定尚未实现。Google／微信每次重试会重新取 challenge 和重新授权，不重复提交可能已被平台消费的 code。

纯本机自动化测试可额外加入 `--developer-login`，使用测试账号密码。该入口仅 Debug 且显式传参时显示；beta 服务禁用密码注册／登录。beta 的 Apple 登录同时交换 authorization code、加密保存 refresh token，删号时先撤销 Apple 授权；完整配置见部署说明。

真实模式会记住选择；重新打开 App 会用 Keychain 中的会话恢复账号，网络失败提供重试，不会切回假数据。设置页可以退出账号。需要原演示界面时，启动参数改为 `--mock-data`；该参数只覆盖本次启动，不删除真实账号数据。

Debug 默认连接 `http://127.0.0.1:8787`，可用 App 环境变量 `MAPTALK_BACKEND_URL` 指向其他本机端口或 HTTPS beta 地址；不接受明文局域网地址。Release 只读取构建时的 HTTPS 配置，没有 Demo 或 localhost 回退。集成测试和 `BackendAccountUITests` 需要设置 `MAPTALK_BACKEND_TEST_URL`；UI 测试隔离 Keychain，并需要现有模拟器提供定位。

发布先保存到账号独立的本地队列，联网后幂等上传；关闭 App 后尚未完成的任务在下次打开时恢复。2026-10-21 已在现有 AWS 主机部署包含 FFmpeg 的 schema 9 服务，POI / Reel 短视频接口已上线；目标 ARM64 隔离测试、备份恢复和 HTTPS 检查通过，真实手机视频发布仍由用户验收。Bubble 后端尚未接入。媒体按权限下载，通过原有卡片显示。Collection 仍是只有名称和内容引用的私密文件夹，按账号保存在当前设备，尚不跨设备同步。

## 当前规则

- 地标 `place` 和个人打卡 `memory` 分开。同一地标可有多个账号的记录，每条记录独立决定公开或私密。
- POI 无文字，允许零或一个媒体（照片或短视频）；Reel 需要文字或媒体，最多九个照片 / 视频混合排列。照片支持 JPEG、PNG、WebP；视频上传使用已在手机压缩的 H.264 MP4，可含单声道 / 双声道 AAC 音频。
- 单段视频最长 60 秒、最多 20 MiB、长边 1280 / 短边 720、最多 60 fps；服务端独立完整解码、校验、去掉位置等元数据，再封装 fast-start MP4。保留竖屏方向，不接受外部媒体引用或播放列表；视频不能作为头像。每账号 50 MiB 总媒体额度保持不变。
- 私密记录和照片只允许本人访问。beta 的公开记录发布后立即向已邀请且未互相屏蔽的成员可见，尚无好友关系限制。未获邀请／已撤销账号不能读取内容；举报下架仍会隐藏违规内容。
- MyMap 返回自己的公开和私密记录。Feed 包含首次公开后 24 小时内的 POI 和 Reel；地图搜索返回视野内的公开历史记录。Feed 到期不会删除记录。
- `createdAt` 是保存时间；`publishedAt` 是首次公开时间，未公开为 `null`。私密记录日后首次公开，从公开时计算 24 小时；反复切换隐私不会刷新动态时间。
- 引用已有地标时，提交坐标必须在该地标 150 米内，与当前 App 的候选地点范围一致。这只校验坐标距离，不能证明用户的真实位置。
- 相同记录 UUID 和相同内容的重试不会重复创建。永久删除后保留 ID 墓碑，旧请求不能恢复已删除记录。

## 接口

除 `/health`、注册、登录及 provider 配置／challenge 接口外，都需要 `Authorization: Bearer <token>`。JSON 请求使用 `Content-Type: application/json`。时间使用 UTC ISO 字符串；所有列表返回 `{ items, nextCursor }`。

| 方法和路径 | 内容 |
| --- | --- |
| `GET /health` | 服务状态及 local-development / private-beta 模式 |
| `POST /v1/auth/register` | `{ handle, password }`，返回用户和会话 |
| `POST /v1/auth/login` | 同上，验证已有账号 |
| `GET /v1/auth/providers` | `{ providers: [{ id, available, reason? }] }`，不包含 secret |
| `POST /v1/auth/apple/challenge` | `{}`，返回 `{ challengeId, nonce, expiresAt }`，5 分钟有效 |
| `POST /v1/auth/apple` | `{ challengeId, identityToken, authorizationCode? }`，beta 要求 code；challenge 只能消费一次 |
| `POST /v1/auth/google/challenge` | `{}`，返回 `{ challengeId, expiresAt }`，5 分钟有效 |
| `POST /v1/auth/google` | `{ challengeId, code }`，服务端兑换 SDK 提供的 serverAuthCode |
| `POST /v1/auth/wechat/challenge` | `{}`，返回 `{ challengeId, state, expiresAt }`，5 分钟有效 |
| `POST /v1/auth/wechat` | `{ challengeId, code, state }`，验证 state 并服务端兑换 code |
| `POST /v1/auth/logout` | 撤销当前会话 |
| `GET /v1/me` | 当前用户：`id`、`handle`、可选的 `avatar` 媒体元数据 |
| `PATCH /v1/me` | `{ handle, avatarMediaId? }`，原子保存用户名与本人已上传头像；省略头像保持不变，null 清除 |
| `DELETE /v1/me` | 撤销 Apple 授权并删除在线账号及所属数据 |
| `GET /v1/beta/access` | `{ required, status }`，status 为 active / pending / revoked |
| `POST /v1/beta/redeem` | `{ code }`，兑换单人邀请码 |
| `POST /v1/reports` | `{ memoryId, reason }`，举报可访问内容 |
| `POST /v1/blocks` | `{ userId }`，双向隐藏该账号的公开内容 |
| `DELETE /v1/blocks/:userId` | 解除自己的屏蔽 |
| `POST /v1/media` | 原始图片 / 已标准化视频字节，Content-Type 为图片类型或 `video/mp4`；支持 UUID `Idempotency-Key` |
| `GET /v1/media/:id` | 权限检查后的媒体字节，支持单个 `Range: bytes=...`；206 / 416 遵循字节范围规则 |
| `HEAD /v1/media/:id` | 相同权限边界下的媒体长度 / 类型，不下载字节 |
| `DELETE /v1/media/:id` | 删除自己未被记录或头像引用的媒体 |
| `POST /v1/memories` | 新建 POI 打卡或 Reel |
| `GET /v1/memories/:id` | 有权限访问的单条记录 |
| `PATCH /v1/memories/:id` | `{ visibility: "public" 或 "private" }` |
| `DELETE /v1/memories/:id` | 永久删除自己的记录 |
| `GET /v1/me/memories` | 自己的全部记录 |
| `POST /v1/me/archive/hide` | `{ kind: "poi" 或 "reel", id }`，仅从自己的 MyMap 移除 |
| `GET /v1/users/:id` | 可访问用户的 ID、用户名和头像元数据 |
| `GET /v1/users/:id/memories` | 该用户的公开历史，包括已退出 Feed 的记录 |
| `GET /v1/feed` | 当前公开动态 |
| `GET /v1/map/memories` | 视野内的公开历史记录 |

创建记录示例，`id` 每条记录生成一次，网络重试保持不变：

```json
{
  "id": "7ddfe1b2-b571-4daa-9b29-4170231e2e5d",
  "kind": "poi",
  "visibility": "private",
  "location": { "latitude": 37.3688, "longitude": -122.0363 },
  "place": { "name": "Test café", "category": "coffee" },
  "mediaIds": []
}
```

已有地标用 `placeId` 替代 `place`，两者不可同时提交。类别沿用 App：`viewpoint`、`restaurant`、`coffee`、`nightlife`、`art`、`market`、`other`。Reel 不传地标，使用 `caption` 和 / 或 `mediaIds`。

Apple 地点首次写入可在 `place` 中附上 `sourceId` UUID 和独立的 `coordinate`。服务用来源 ID 合并同一地标，不用拍摄位置覆盖地标位置；随后引用同一 ID 不能改写已有名称或坐标。目前来源 ID 由客户端提供，服务未向 Apple 验证。

列表接受 `limit`（1–100，默认 50）和上次返回的 `cursor`。Cursor 是不透明值，只用于同一查询的下一页。Feed 按首次公开时间降序；MyMap 和地图历史按保存时间降序。地图接口必须提供 `west`、`east`、`south`、`north`，支持跨越国际日期变更线。

常见错误：未登录 `401`；不可见资源 `404`；内容与已有 ID 冲突 `409`；自己的 ID 已永久删除 `410`；输入不合法 `422`；登录频率过高 `429`。错误体为 `{ error: { code, message } }`。

永久删除接口**不是** App 的“从 MyMap 移除”动作。本人列表行的菜单提供 Make private 和 Delete post；同一 POI 有多次打卡时按记录分别操作，不删除共享地标或其他人的记录。删除记录撤销对应公开访问；未引用媒体可通过媒体删除接口移除，删号会清除该账号的在线媒体。

App 的 MyMap 移除动作连接 `archive/hide`：Reel 使用记录 ID，POI 使用地标 ID，移除自己在该地点的整组记录。公开帖子、公开主页和其他账号的访问不受影响。重新打卡会让该地标回到 MyMap；重试旧请求不会重新显示。

## 备份和恢复

账号、会话、记录及照片字节都在同一个数据库中。使用 SQLite 在线备份读取完整快照，不要直接复制运行中的主数据库文件：

```sh
npm run backup -- /absolute/path/to/new-backup.sqlite
```

备份不会覆盖已有文件。恢复时先停止服务，然后以新文件作为数据库启动，保留原文件：

```sh
MAPTALK_DATABASE=/absolute/path/to/new-backup.sqlite npm start
```

上面的 `backup` 是本机开发用明文备份。beta 自动使用加密备份，并提供 `npm run backup:encrypted -- create ...` / `restore ...`；完整操作及异地复制要求见 [部署说明](DEPLOYMENT.md)。数据库、明文临时副本、密钥、备份和 `.env` 都必须保持在 Git 之外。

## 接入和上线前的范围

本地闭环不等于全部产品功能完成。照片读取使用授权请求，不提供永久公开链接；账户恢复仍依赖本机保存的会话，没有忘记密码流程。

Collection 已做本机按账号保存，Bubble 仍是发布时附带的内容，尚无服务端实现，没有将两者变成另一类公开帖子。用户名和头像支持真实账号保存；好友、聊天、评论、点赞、推送仍未接入，真实模式隐藏 Chats 和其他未连接的社交入口。原卡片中的其他演示操作不代表服务器已经支持，不能纳入亲友验收承诺。

上传图片先完整解码再转为最大长边 2048 的 JPEG，移除 EXIF/GPS 等元数据；拒绝损坏／动画／过大图片，限制处理并发。输入单张最多 10 MiB，每账号媒体限额 50 MiB。短视频处理并发为 1，解码 / 探测均有时限，下载按 64 KiB 分块与背压读取，不会为每次播放范围请求复制整段视频。照片和短视频字节仍随 SQLite 持久化，只面向小规模内测，不是无限视频／大规模对象存储方案。上线仍需平台凭证、实际 HTTPS 部署、隐私及支持页面、审核负责人、异地备份和真机网络验收；美国、中国大陆和欧洲不能仅凭本机通过就承诺可用。
