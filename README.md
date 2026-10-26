# AWS VPC Peering — VCS-Driven Workflow on HCP Terraform

Frontend VPC (`10.0.0.0/16`) and backend VPC (`192.168.0.0/16`) in **eu-west-1**, joined by VPC peering and deployed by **HCP Terraform VCS-driven runs** from this GitHub repository.

| Item | Value |
|---|---|
| HCP Terraform organization | `waiaung-vpc-lab` |
| HCP Terraform project | `aws-vpc-peering-infra` |
| AWS region | `eu-west-1` (Ireland) |
| AWS authentication | OIDC dynamic credentials (separate Plan / Apply roles) |
| SSH keys | Created on Mac, stored in AWS Secrets Manager, read as ephemeral values |
| Policy as code | OPA policy `network-guardrails` (mandatory, 3 rules) |
| Status | Deployed, verified, then destroyed |

**Security goals**

1. No static AWS access keys anywhere.
2. The SSH private key never appears in this repository, a plan file, a state file or a run log.
3. Every role and rule grants only what it needs.

---

## 1. Architecture

| | Frontend VPC `10.0.0.0/16` | Backend VPC `192.168.0.0/16` |
|---|---|---|
| Public subnets 01–03 | `10.0.1-3.0/24` → Internet Gateway | `192.168.1-3.0/24` → Internet Gateway |
| Private subnet01 | `10.0.253.0/24` → NAT Gateway | `192.168.253.0/24` → NAT Gateway |
| Private subnet02 | `10.0.254.0/24` ↔ VPC peering | `192.168.254.0/24` ↔ VPC peering |
| Private subnet03 | `10.0.255.0/24` ↔ VPC peering | `192.168.255.0/24` ↔ VPC peering |
| Public instance01 | Amazon Linux 2023, Elastic IP, httpd, bastion | same |
| Private instances 01–03 | Ubuntu 24.04 | Ubuntu 24.04 |

- **Access path:** Mac → public instance01 (bastion) → private instance01 → private instance02 / 03
- **Peering routes:** only private subnet02 ↔ 02 and 03 ↔ 03
- **Peering security groups:** SSH + ICMP allowed only between private SG02 ↔ SG02 and SG03 ↔ SG03 (security-group references, not CIDRs)

---

## 2. Workspaces (monorepo — one folder = one workspace)

| Order | Workspace | Working directory | Trigger pattern | Builds | Reads outputs from |
|:-:|---|---|---|---|---|
| 1 | `fe-network-ws` | `fe-network` | `fe-network/**/*` | Frontend VPC, subnets, IGW, NAT, route tables | — |
| 2 | `be-network-ws` | `be-network` | `be-network/**/*` | Backend VPC, subnets, IGW, NAT, route tables, **peering** | fe-network |
| 3 | `fe-security-ws` | `fe-security` | `fe-security/**/*` | Frontend security groups | fe-network |
| 4 | `be-security-ws` | `be-security` | `be-security/**/*` | Backend security groups + **cross-VPC rules (both sides)** | be-network, fe-security |
| 5 | `fe-compute-ws` | `fe-compute` | `fe-compute/**/*` | Key pair, public + 3 private instances | fe-network, fe-security |
| 6 | `be-compute-ws` | `be-compute` | `be-compute/**/*` | Key pair, public + 3 private instances | be-network, be-security |

Peering lives in `be-network` and the cross-VPC rules in `be-security` because frontend and backend reference each other. Frontend is created first and backend adds the links, which avoids a circular dependency.

**Workspace settings (all six)**

- Version control workflow, repository `waiaung-wa/aws-vpc-peering-vcs-lab`, branch `main`
- VCS trigger: branch-based, *only trigger runs when files in specified paths change* (pattern above)
- Automatic speculative plans for pull requests: on
- Apply method: manual

**Remote state sharing** (source → shared with)

| Source | Shared with |
|---|---|
| `fe-network-ws` | `be-network-ws`, `fe-security-ws`, `fe-compute-ws` |
| `be-network-ws` | `be-security-ws`, `be-compute-ws` |
| `fe-security-ws` | `be-security-ws`, `fe-compute-ws` |
| `be-security-ws` | `be-compute-ws` |

> The `cloud {}` block in each `versions.tf` is only used by CLI runs. VCS-driven runs are bound to their workspace in the HCP UI (repository + working directory + trigger pattern). The `organization` value in `data.tf` / `variables.tf` is still required for `terraform_remote_state`.

---

## 3. AWS authentication — OIDC

**IAM (AWS account)**

| Resource | Details |
|---|---|
| OIDC provider | `https://app.terraform.io`, audience `aws.workload.identity` |
| `HCP-VPC-Lab-Plan-Role` | `ReadOnlyAccess` + inline `ReadVpcLabSshKeys` |
| `HCP-VPC-Lab-Apply-Role` | `AdministratorAccess` (lab only) + inline `ReadVpcLabSshKeys` |

Trust policy condition (`run_phase:apply` for the Apply role):

```json
"StringEquals": { "app.terraform.io:aud": "aws.workload.identity" },
"StringLike":   { "app.terraform.io:sub": "organization:waiaung-vpc-lab:project:aws-vpc-peering-infra:workspace:*:run_phase:plan" }
```

Only workspaces in this organization and project can assume the roles, and each role only in its own run phase.

**HCP Terraform variable set** `aws-oidc-eu-west-1` (scope: whole project, category: Environment)

| Key | Value | Sensitive |
|---|---|---|
| `TFC_AWS_PROVIDER_AUTH` | `true` | No |
| `TFC_AWS_PLAN_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/HCP-VPC-Lab-Plan-Role` | Yes |
| `TFC_AWS_APPLY_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/HCP-VPC-Lab-Apply-Role` | Yes |

---

## 4. SSH keys — Mac → AWS Secrets Manager → ephemeral read

```bash
ssh-keygen -t ed25519 -N "" -C "frontend@vpc-lab" -f ~/.ssh/vpc-lab/frontend-ssh-key
aws secretsmanager create-secret --region eu-west-1 --name vpc-lab/frontend/ssh-private-key --secret-string file://$HOME/.ssh/vpc-lab/frontend-ssh-key
aws secretsmanager create-secret --region eu-west-1 --name vpc-lab/frontend/ssh-public-key  --secret-string file://$HOME/.ssh/vpc-lab/frontend-ssh-key.pub
# same for backend
```

| Secret | Read by Terraform as | Used for |
|---|---|---|
| `vpc-lab/<tier>/ssh-public-key` | `data "aws_secretsmanager_secret_version"` | `aws_key_pair` |
| `vpc-lab/<tier>/ssh-private-key` | `ephemeral "aws_secretsmanager_secret_version"` | provisioner `connection` blocks only |

The inline policy `ReadVpcLabSshKeys` allows `secretsmanager:GetSecretValue` and `DescribeSecret` on `arn:aws:secretsmanager:eu-west-1:<ACCOUNT_ID>:secret:vpc-lab/*` only. Both roles need it because `terraform plan` also reads the secrets.

Provisioners are re-run only when the instance or `files/deploy_app.sh` changes (`triggers = { instance_id, script_hash }`).

---

## 5. Policy as code — OPA

Policy set `vpc-lab-network-policies` (individually managed, OPA) is enforced on `fe-network-ws` and `fe-security-ws`. It contains one **mandatory** policy, `network-guardrails`, with three rules — see [`policies/network-guardrails.rego`](policies/network-guardrails.rego).

| Rule | What it blocks | Why |
|---|---|---|
| 1 | More than 6 subnets in a VPC workspace | Keeps the network design fixed and reviewed |
| 2 | `map_public_ip_on_launch = true` on a subnet | Instances must not get public IPs automatically (AWS Security Hub EC2.15) |
| 3 | `aws_vpc_security_group_ingress_rule` with SSH (22) from `0.0.0.0/0` | Private security groups must never be reachable from the internet |

Query: `data.terraform.policies.network_guardrails.deny`

**Test results**

| Test | Change | Result |
|---|---|---|
| Pass | Current `main` | All rules passed |
| Deny | Pull request adding a 7th subnet with `map_public_ip_on_launch = true` and an SSH-from-internet rule on private SG01 | `fe-network-ws`: Rule 1 + Rule 2 failed · `fe-security-ws`: Rule 3 failed · pull request closed without merge |

Notes:
- HCP Terraform Free allows one mandatory policy, so the three rules share one policy; each rule prints its own `[Rule n]` message.
- Rule 3 checks standalone rule resources only. The public security groups keep inline SSH from `0.0.0.0/0` because HCP Terraform runners need it for provisioners (see limitations).

---

## 6. Change workflow (GitOps)

```bash
git checkout -b feature/fe-compute-instance-type
# edit files in fe-compute/
git add fe-compute/
git commit -m "Change frontend instance type"
git push -u origin feature/fe-compute-instance-type
```

1. Open a pull request → only the matching workspace runs a speculative plan (+ OPA) and reports it as a PR check.
2. Review → merge → a real run starts on `main`.
3. Confirm & apply in HCP Terraform.

Change one folder per pull request so workspaces run in dependency order.

---

## 7. Verification

```bash
ssh-add ~/.ssh/vpc-lab/frontend-ssh-key
ssh-add ~/.ssh/vpc-lab/backend-ssh-key
curl http://<frontend_public_instance_public_ip>
ssh -A -J ec2-user@<FE_PUBLIC>,ubuntu@<FE_PRIV01> ubuntu@<FE_PRIV02>
ping -c 3 <BE_PRIV02>   # works  (SG02 <-> SG02)
ping -c 3 <BE_PRIV03>   # fails  (SG02 -> SG03 not allowed)
```

| Check | Result |
|---|---|
| Web page on frontend public instance | Served by httpd |
| SSH bastion → private instance01 → private instance02 | Works |
| Ping fe private02 → be private02 / fe private03 → be private03 | Works |
| Ping fe private02 → be private03 | Blocked |
| `grep -c "PRIVATE KEY"` on downloaded state | `0` |
| CloudTrail `GetSecretValue` | Called by the HCP Plan / Apply role sessions |

---

## 8. Destroy (reverse order)

`be-compute` → `fe-compute` → `be-security` → `fe-security` → `be-network` → `fe-network`, then delete the four secrets:

```bash
aws secretsmanager delete-secret --region eu-west-1 --secret-id vpc-lab/frontend/ssh-private-key --force-delete-without-recovery
# repeat for frontend/ssh-public-key, backend/ssh-private-key, backend/ssh-public-key
```

---