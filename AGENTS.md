# MapTalk AWS setup

- AWS CLI profile: `maptalk`.
- Project selected Region: `us-east-2` (provided by the user).
- Agent Toolkit uses its service endpoint in `us-east-1`; this does not change the project's deployment Region.
- Tool installation does not authorize deploying the app, enabling paid services, or changing billing settings. Confirm the deployment scope and cost before creating resources.
- Keep existing application changes intact. AWS tool setup must not change the app's UI or application code.
- Preferred help level: `MEDIUM` (关键处确认), selected by the user.
- On 2026-10-19 the user accepted the approximately USD 25/month planning budget and authorized starting the discussed private-beta deployment: one EC2 t4g.small in us-east-2, 30 GiB total encrypted gp3 storage, one public IPv4, and private S3 encrypted backups. Normal pricing, excluding credits, tax, domain costs, and excess transfer; this is not a hard billing cap.
- Do not silently upgrade the AWS plan, purchase a domain, or add paid services beyond that scope. Confirm any cost/scope expansion before acting. Deployment authorization does not waive DNS/TLS, Apple configuration, backup restore, or real-device acceptance checks.
- On 2026-10-19 the user confirmed purchasing `maptalkapp.com` and authorized its use for MapTalk. The planned API hostname is `api.maptalkapp.com`; public DNS is managed by Cloudflare. Preserve unrelated DNS records, do not register another domain or create a Route 53 hosted zone, and only switch the iOS app to the remote endpoint after DNS/TLS and backend health are verified.
- On 2026-10-20, with explicit user approval, the Apple key `MapTalk Sign In` was created with only Sign in with Apple enabled for `com.chengsi.maptalk` (Team ID `H28S4PM4KP`, Key ID `P2TYDWHP4C`). The downloaded P-256 private key is stored outside the repository at `/Users/chengsya/.config/maptalk/secrets/AuthKey_P2TYDWHP4C.p8` (directory mode 0700, file mode 0400). Do not print its contents, commit it, bundle it in the app, or create/revoke replacement keys without approval. This is local credential preparation, not proof of deployed or tested Apple authentication.
- On 2026-10-20, after an explicit scope/cost confirmation request, the user said “继续” and authorized deployment-code transfer (without secrets) through their private S3 bucket and storage of the existing Apple private key plus the two existing encryption keys in three Secrets Manager secrets in their AWS project in us-east-2. Incremental normal cost is approximately USD 1.20/month plus API requests; base estimate approximately USD 20/month, within the USD 25 planning budget (not a hard cap). Use AWS-managed encryption, no new paid customer-managed KMS keys, no automatic secret rotation, and no cross-Region replication. Do not upload secrets.tar to S3. This approval resolves the prior sensitive-transfer blocker only for these named destinations and payloads.
- On 2026-10-20 (America/Los_Angeles), the user explicitly approved updating the existing backend for offline publishing and then installing the compatible app on the connected iPhone. This authorizes an in-place schema 7→8 upgrade with encrypted backup/restore verification and an app update without uninstalling; no new cloud services, quota increases, key rotation, or phone UI testing are authorized by this approval.
- On 2026-10-21 (America/Los_Angeles), the user explicitly requested “更新啊后端” after installing the video-capable client. This authorizes the in-place schema 8→9 video release on the existing EC2, including FFmpeg in the runtime image, proxy timeout alignment, encrypted backup/restore verification and isolated synthetic-video tests. Resource sizes, the 50 MiB/user media quota, keys and the existing approximately USD 20/month base estimate remain unchanged; no new cloud services, plan upgrade or physical-phone UI testing is authorized.
- On 2026-10-21 (America/Los_Angeles), after confirmation of backup, existing-backend upgrade and phone installation, the user replied “enen”, authorizing the schema 9→10 resumable-video release and installation of the compatible gesture/upload fixes over the existing iPhone app. Verify encrypted backup/restore, unchanged old data and isolated target-platform upload tests before cutover. Preserve pending local uploads; no uninstall, phone UI testing, new services, resource upgrade, quota increase or key changes.
- On 2026-10-22 (America/Los_Angeles), the user explicitly approved updating the existing backend for authored-caption editing and airport landmark selection after tests, encrypted backup and restore verification. This authorizes an in-place schema 10→11 upgrade adding optional airport directory metadata while preserving old data, current GPS publication coordinates, keys, quotas and existing resource sizes/cost plan. No new cloud services, expansion or phone UI testing are authorized. Install the compatible client only when the user requests it.

- On 2026-10-23 (Pacific/Honolulu), the user explicitly approved updating the existing backend for text-only post/place comments after local tests and encrypted backup/restore verification. This authorizes an in-place schema 11→12 upgrade adding comment storage while preserving existing records, media, pending uploads, publication times, keys, quotas and resource sizes. No new cloud services, cost-plan expansion or physical-phone UI testing; install the client only when requested.
- On 2026-10-23 (Pacific/Honolulu), after the existing Apple Development certificate expired, the user approved creating a replacement development signing certificate and an in-place iPhone update. Following the user's Xcode account login, a valid development identity became available; the compatible schema 12 client was signed, verified and installed without uninstalling. This does not authorize certificate revocation, changes to the Sign in with Apple server key, or physical-phone UI testing.
- On 2026-10-26 (Pacific/Honolulu), after the 50 MiB per-user media quota was identified as the main live upload blocker, the user said “给1g”, authorizing the existing backend's per-user total media quota to increase to 1 GiB (1,073,741,824 bytes). This is a runtime configuration-only update using the same image, schema, keys and resource limits; no new cloud services, disk resize, single-video limit increase, phone installation or UI testing. Actual media, full-database backups and transfer usage can grow; this is not a 1 GiB reserved allocation or a guarantee that the 20 GiB data disk can hold 20 fully used accounts. Keep the existing cost scope and seek approval before infrastructure expansion.

<!-- BEGIN AWS Agent Toolkit rules -->
# AWS Guidance for the new AWS experience

This user has signed up for the new AWS experience. This experience lets you sign into AWS using a social provider and requires the following additional context.

Where this guidance conflicts with the project's own instructions, the project's instructions take precedence.

## Context

### Terminology:

- Say "project" instead of "account" — a project contains an AWS account and settings for sharing with other collaborators
- Say "team member" instead of "IAM user" — users are invited by email, not created or federated in IAM
- Say "AWS Settings" when referring to management tasks at [settings.aws.com](https://settings.aws.com/) (project management, billing, team members, spend limits). Users view their actual AWS resources in the AWS Management Console.
- Say "selected Region" when referring to the user's Region — not "home Region"
- The user has a managed IAM experience. This includes a managed service control policies (SCP) and resource control policies (RCP) that govern the use of AWS. They will still need to use IAM to create policies to let services work with each other. If there are questions about the SCPs or RCPs, go to the documentation at https://docs.aws.amazon.com/accounts/latest/reference/scps-and-rcps-for-projects.html

### Constraints:

- All projects share a single AWS Region determined by the user's contact address. Resources cannot be created in other Regions
- When developing:
  - MUST create all Regional resources in the project's assigned Region
  - You CAN create AWS WAF and Cloudwatch Logs resources in us-east-1 when there are global resources (like a global WAF instance) that require a connection to dependencies in us-east-1. You should not use these for any other reason, because resources in the selected Region will provide lower cost (due to no cross-Region traffic), increased availability (due to no cross-Region traffic), and easier manageability (due to not needing to look in another Region). When you need to do an inventory of resources, you need to look in both the selected Region and us-east-1 for Cloudwatch Logs or WAF resources.
  - MUST NOT attempt to create Lambda, API Gateway, or other Regional resources in any other Region
  - MUST direct users to confirm their Region in AWS Settings > View all projects > Overview > Additional Info > Region. If the user cannot confirm their Region, check in ~/.aws/config
  - MUST NOT use Lambda@Edge — excluded from both Lambda and CloudFront
  - MUST NOT use CloudFormation StackSets — no multi-account or multi-Region deployments
  - MUST NOT attempt cross-Region actions — no cross-Region replication for DynamoDB/S3/RDS, no multi-Region KMS keys
  - MUST NOT use Route 53 cross-Region routing — geolocation, latency-based, and failover routing policies are not available
  - CloudFront is a global service and its actions ARE allowed in `us-east-1`. A user can create a CloudFront distribution pointing to their project-region Lambda function URL or API Gateway. However, Lambda and API Gateway themselves MUST NOT be created in `us-east-1` — they must be in the project Region.
  - Reduced availability in `eu-north-1` specifically: Amazon Rekognition, Amazon Textract, Amazon Personalize, AWS App Runner are not available in that Region.
- IAM permissions for human access are managed by AWS. Don't assign roles to team members unless absolutely necessary
- The user may have a spend limit if they are on the paid plan. The limit that pauses their project if it's exceeded. If resources suddenly become inaccessible, ask if they have a spend limit configured. Only project owners can modify a spend limit.
- When developing:
  - MUST ask about spend limit status if the user reports sudden "Access Denied" errors on operations that previously worked
  - MUST direct users to check spend status in AWS Settings > Billing
  - MUST check if a user has upgraded their account to the paid plan
  - MUST ask the user if they want to clean up the successfully created resources or keep them to reduce cost
- The user sets up billing, creates spend limits, and retrieves and pays invoices in AWS Settings. The user creates budgets and optimizes their costs in the AWS Billing and Cost Management console
- Not all AWS services are available. If a service isn't working, do the following:
  1. Run the command `aws freetier get-account-plan-state`
  2. If accountPlanType": "FREE", check the [Free Tier supported services list](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html#supported-services-free-tier) next,
  3. If accountPlanType": "PAID", check the [Paid Tier supported services list](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html#supported-services-paid-plan).
  4. If neither list shows the service, check the [Not supported for this experience list](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html#unsupported-services). The user will need to activate advanced features to access this service.
- Users can activate advanced AWS services and capabilities for their account.
- Before starting a task, check whether a relevant AWS skill is available. Load the skill with retrieve_skill and prefer its guidance over general knowledge.

### Help level

- help_level (required): LOW, MEDIUM, or HIGH. While a user is building, you MUST ask the user: "How much guidance would you like from me? Low (I only flag security risks), medium (I ask a couple of clarifying questions if something seems off), or high (I explain what I'm doing, suggest alternatives, and flag best practices)."

You CAN update this rule file to save a user's help_level.

Constraints for each level:

**LOW:**

- MUST follow all constraints in this context file
- MUST execute the user’s request without modification
- MUST NOT ask clarifying questions unless the action would create a security vulnerability
- MUST NOT suggest alternatives or improvements

**MEDIUM:**

- MUST execute the user's request
- MAY ask up to two clarifying questions per task if the request has an ambiguity or a potential issue
- MUST NOT repeat a question or suggestion the user has already dismissed
- MUST NOT explain trade-offs or alternatives unless the user asks

**HIGH:**

- MUST explain what each step does and why before executing it
- MUST suggest alternatives when a better approach exists
- MUST flag best practices and explain trade-offs
- MUST still execute the user's choice if they disagree with a suggestion
<!-- END AWS Agent Toolkit rules -->
