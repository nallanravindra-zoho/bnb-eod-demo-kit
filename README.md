# Bharat National Bank — Branch EOD Processing Demo Kit

A 30-minute, use-case-driven AWS demo for the **AWS Cloud Architecture, Automation & Security** program.
"Bharat National Bank" is a **fictional** bank. All data in `sample-data/` is synthetic.

Presenter run sheet: **[docs/PRESENTER_SCRIPT.md](docs/PRESENTER_SCRIPT.md)**
Architecture slide: `docs/architecture.png`

## What's in the kit

| Path | What it is | When it's used |
|---|---|---|
| `cloudformation/portal-stack.yaml` | Custom VPC (2 AZs, public/private subnets, IGW, NAT), ALB, Launch Template, ASG | Deployed **the day before** |
| `terraform/foundation/` | CodePipeline (Source → Tests → Manual Approval → Deploy), 2 CodeBuild projects, read-only auditor IAM user | Deployed **the day before** and left running |
| `terraform/platform/` | KMS CMK, 2 encrypted S3 buckets, Secrets Manager secret, Lambda + least-privilege role, S3 trigger | Applied **live** in Act 1 |
| `lambda/` | EOD file processor (`config.py` holds the ₹ threshold you change live) | |
| `tests/` | Unit tests CodeBuild runs before any deploy, including a policy ceiling of ₹10 lakh | |
| `buildspec.yml`, `buildspec-deploy.yml` | CodeBuild instructions for the test and deploy stages | |
| `sample-data/` | `branch_0457_eod.csv` (20 txns) and `branch_0457_eod_CORRUPT.csv` (bad amount format) | Uploaded live |

**Expected results with `branch_0457_eod.csv`:** threshold ₹10 lakh → **2** flagged; threshold ₹5 lakh → **5** flagged.
**Corrupt file:** rejected with `Line 4: amount '12,50,000' is not a valid number`.

## Prerequisites
- AWS account with an admin IAM user (MFA on), region **ap-south-1 (Mumbai)**
- AWS CLI v2, Terraform ≥ 1.5, git, a GitHub account
- Two browser profiles: **Presenter** (admin) and **Auditor** (signed in as `bnb-branch-auditor`)

## Setup — the day before (about 45 minutes)

**1. Push this kit to a new GitHub repo** (private is fine), branch `main`.

**2. Deploy the portal stack** (takes about 5 minutes):
```bash
aws cloudformation deploy --region ap-south-1 \
  --template-file cloudformation/portal-stack.yaml --stack-name bnb-branch-portal
aws cloudformation describe-stacks --region ap-south-1 --stack-name bnb-branch-portal \
  --query "Stacks[0].Outputs" --output table
```
Open `PortalURL` and refresh a few times. The instance ID and AZ should change.

**3. Create the GitHub connection:** Console → Developer Tools → Settings → **Connections** → Create connection → GitHub → install the AWS Connector app on your repo. The status must show **Available**. Copy its ARN.

**4. Deploy the foundation:**
```bash
cd terraform/foundation
cp terraform.tfvars.example terraform.tfvars   # fill connection_arn + repository_id
terraform init && terraform apply
terraform output -raw auditor_password         # run OFF-SCREEN; save it in the Auditor browser profile
```
Sign in to the Auditor profile using `auditor_signin_url` and check that the login works.

**5. Enable GuardDuty** in ap-south-1 (Console → GuardDuty → Get started → Enable). New accounts get a 30-day free trial.

**6. Full rehearsal:**
```bash
cd ../platform && terraform init && terraform apply      # builds the platform
aws s3 cp ../../sample-data/branch_0457_eod.csv s3://bnb-eod-incoming-<ACCOUNT_ID>/eod/ --region ap-south-1
```
Then change `lambda/config.py` to `5_00_000`, push, approve, re-upload, and confirm 5 are flagged.

**7. Reset for demo day:**
```bash
terraform destroy          # in terraform/platform — the demo re-creates it live
```
Set `lambda/config.py` back to `THRESHOLD_INR = 10_00_000` and push. That push starts the pipeline; it will stop at **Change-Approval**. Click **Reject** there. Keep `terraform init` done so the live apply is fast.

**8. Record backup videos** of Act 2 (instance kill → ASG replacement) and Act 4 (pipeline run), in case the network is slow on the day.

## Demo-day morning (10 minutes)
- [ ] Portal URL loads; target group shows **2 healthy** targets
- [ ] `terraform/platform` is **destroyed** and `terraform plan` shows **18 to add**
- [ ] `config.py` on GitHub says `10_00_000`; no pipeline execution is waiting at approval
- [ ] Auditor profile signed in; Presenter profile signed in with tabs open (see presenter script)
- [ ] Terminal font enlarged; notifications off; two copies of the repo are not open (avoid pushing from the wrong one)

## Notes for Q&A
- **Why CodeBuild deploys the Lambda:** it's the fastest and most predictable option for a live demo. In the training (Day 4), CodeDeploy is used for EC2 in-place deployments.
- **CloudTrail Event History shows management events** (e.g., `TerminateInstances`, `PutApprovalResult`, `UpdateFunctionCode`). Object-level S3 reads and writes are *data events* and need a trail with data events enabled. That's covered on Day 5.
- **DR:** the production design would replicate the processed bucket to **Hyderabad (ap-south-2)** with S3 CRR — Day 2.
- `force_destroy` and `recovery_window_in_days = 0` are **demo-only** settings so the environment can be rebuilt quickly. Production would not use them.

## Cost & cleanup
The portal stack (NAT Gateway, ALB, 2 × t3.micro) costs roughly a few US dollars per day it's left running. Check the current pricing for ap-south-1. Clean up right after the demo:
```bash
cd terraform/platform   && terraform destroy
cd ../foundation        && terraform destroy
aws cloudformation delete-stack --region ap-south-1 --stack-name bnb-branch-portal
```
Also disable GuardDuty and delete the GitHub connection if they're no longer needed. The KMS key is scheduled for deletion (7-day window).
