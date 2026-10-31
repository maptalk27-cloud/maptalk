# MapTalk TestFlight 准备与真机验收

日期：2026-10-28，Pacific/Honolulu。

本轮准备亲友 TestFlight 内测，不是公开 App Store 上架。Release 候选归档已生成并验证；上传前仍需用户确认。没有上传、邀请测试者、安装真机、部署后端或扩大云资源。

## 候选版本

| 项目 | 当前值 |
| --- | --- |
| 名称与版本 | MapTalk 1.0，build 1 |
| Bundle ID | com.chengsi.maptalk |
| 设备要求 | iPhone，iOS 26.0 或更新版本 |
| API | https://api.maptalkapp.com |
| 归档 | output/testflight-2026-10-28/MapTalk-1.0-1.xcarchive |
| 签名 | 现有 Apple Development 签名，完整性校验通过；不是已导出的 App Store 分发包 |
| 源码 | b9b56a94be1adc36d1e3ec1bd382bd5089565d2f 加当前未提交改动 |

归档主程序 SHA-256：`2ecb1e3bb064db5f729b2e31cf2293a2f0df1247c5e328567133680d0cb7ae7f`。

`Config/TestFlightExportOptions.plist` 已准备，使用 `app-store-connect` 和 `destination=export`，不自动上传、不自动修改构建号。尚未执行分发导出，也未申请分发证书。归档目录已单独设置 Git 忽略规则。

本轮除卡片布局外，只修正设置页过时的删除说明：MyMap 删除自己的记录也会撤回对应公开帖子；删除自己的地点记录不删除其他人的打卡。删除逻辑未改。

## 已完成验证

| 检查 | 结果与范围 |
| --- | --- |
| iOS 单元测试 | 364 项通过，43 个 suite；未开启需要独立 HTTP 服务的可选 iOS 联调场景 |
| 本地后端测试 | 276 项通过，0 失败、0 跳过；部署预检的 6 项包含在此数内 |
| 本地后端演练 | 双账号、公开与私密隔离、服务重启、独立备份恢复四组通过；不等于生产库恢复验证 |
| 关键 UI 回归 | 原模拟器上 16 项通过，0 失败；涵盖直接地图卡片、照片查看、上下拉手势、人物切换与飞行、Bubble 返回、发布面板、MyMap 多选、离线 Demo 入口 |
| 相册视频专项 | 同一模拟器用合成照片与视频，2 项通过，0 失败、0 跳过；POI 视频导入、预览与重拍，以及 Reel 混合媒体预览返回和长按后草稿保留 |
| Release 归档 | 编译成功；签名完整性与复制后主程序哈希一致 |
| 线上只读健康检查 | `/health` 返回 ok、private-beta；公开 provider 配置仅 Apple 可用 |

以上共 18 项选定 UI 测试，不是全部 UI 测试，也不代替真实设备上的相机、声音和网络上传验收。

测试记录在本机临时目录，必要时保留后再清理：

- `/private/tmp/maptalk-release-unit-20261028.xcresult`
- `/private/tmp/maptalk-release-ui-20261028.xcresult`
- `/private/tmp/maptalk-publish-video-release-20261028.xcresult`
- `/private/tmp/maptalk-release-backend-tests-20261028.log`
- `/private/tmp/maptalk-release-backend-demo-20261028.log`
- `/private/tmp/maptalk-release-backend-preflight-20261028.log`
- `/private/tmp/maptalk-testflight-candidate-20261028.log`

## 上传前需要完成

1. **建立 App 记录和分发签名。** 已登录的 App Store Connect 显示 No Apps，当前没有构建号冲突；尚未验证 MapTalk 商店名称是否可用。本机只有开发签名，需完成 App Store 分发签名或 Apple 管理的分发流程，不能直接把现有归档称为可上传 IPA。建立记录、申请签名及上传前确认范围；本轮不修改 Apple 账号配置。
2. **使 Reel 气泡与线上后端兼容。** 本地支持 schema 13，最后部署记录仍是 schema 12。公开健康接口不报告 schema，所以本轮没有远程确认数据库版本。Reel 携带 cluster 的完整真机验收需先核实并批准现有后端更新，完成真实加密备份、恢复和迁移验证。新 POI 卡片展示本身不依赖未部署的完整地点历史接口。不可因为 Demo 可以打开气泡就宣称线上发布已接通。
3. **准备内测资料和进入方式。** 需要确认反馈邮箱、审核联系人、Apple 登录后的内测邀请码领取方式；不把密码或邀请码写进仓库。隐私与支持 URL 当前未配置，需要准备真实页面。测试说明和外部测试材料按 [Apple TestFlight 指引](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) 填写；首次外部亲友构建需要 [TestFlight Beta App Review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)。
4. **确认出口加密申报。** 当前没有填写 `ITSAppUsesNonExemptEncryption`；上传时依据实际加密使用回答 Apple 的问题，不代替用户猜填法律声明。参见 [Apple 出口合规说明](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)。

## 本轮内测的功能边界

- 真实服务当前只有 Apple 登录；Google、WeChat 未配置，不能作为本轮已上线功能。
- 真实账号的 Chats 入口仍隐藏。地图上的赞与收藏是统计展示，不代表已接通可持久化的社交操作。
- 上传会保存进度并在重新进入应用后续传；锁屏后只有有限后台宽限，不承诺整夜持续上传。
- 每人累计媒体配额为 1 GiB。单视频仍有 60 秒、处理后 20 MiB、源文件 512 MiB 的规则，不能把总配额当成单文件上限。
- Collections 是本机整理，不作为跨设备云同步功能承诺。

## 真机验收

由用户在自己的手机操作；覆盖升级，不卸载。以下项目需要真实 Apple 登录和网络，不能由 Demo 回归代替。

1. 原账号升级后，旧 MyMap、Collections、未完成上传和本地预览仍在；离线重开不要求重新登录。
2. 直接点地图 POI 与从人物故事进入分别检查：顶部地点、右下统计，点照片打开大图，返回同一条；上下拉不闪屏、不切错人物。
3. 人物最后一条继续滑动能进入下一个人并带动地图；直接地图卡片不串入人物会话。
4. POI 随手拍、长按录制、照片加字；Reel 混合照片和视频。检查声音、相册取消、竖横画面、最大允许时长；气泡发布在后端兼容完成后验收。
5. 上传中切 Wi-Fi 与蜂窝、断网、锁屏再打开。检查自动续传、无重复发布、草稿和本地媒体不丢；超配额或不支持的媒体应给出准确可恢复的提示。
6. 用两个真实账号核对公开与私密可见性、删帖同步、文字评论、重复地点打卡人数去重、72 小时后的动态与地点历史。若出现私密泄露、数据丢失或无法恢复上传，停止邀请更多测试者。

## TestFlight 文案草稿

Beta description:

MapTalk is an invite-only map for sharing photos, videos and place visits, and privately organizing memories in MyMap.

What to test:

Please test Apple sign-in, public and private posting, photo and video previews, map and person-story navigation, MyMap collections, comments, and upload recovery after a network interruption. Check that returning from photos or place history keeps the same post selected. Please include your iPhone model, iOS version and reproduction steps with feedback.

以上为待填写草稿，不包含尚未完成的气泡线上发布、聊天或其他登录方式承诺。反馈地址、审核联系人、进入方式及最终功能范围确认后再填入 App Store Connect。
