# OPA policy used in HCP Terraform (policy set: vpc-lab-network-policies)
# Name:        network-guardrails
# Enforcement: mandatory
# Query:       data.terraform.policies.network_guardrails.deny

package terraform.policies.network_guardrails

import rego.v1
import input.plan as plan

# ---------- Rule 1: at most 6 subnets per VPC workspace ----------
max_subnets := 6

subnets := [r.address |
  some r in plan.resource_changes
  r.mode == "managed"
  r.type == "aws_subnet"
  r.change.actions != ["delete"]
]

deny contains msg if {
  count(subnets) > max_subnets
  msg := sprintf("[Rule 1] This workspace would have %d subnets; the maximum allowed is %d.", [count(subnets), max_subnets])
}

# ---------- Rule 2: subnets must not auto-assign public IPs ----------
deny contains msg if {
  some r in plan.resource_changes
  r.mode == "managed"
  r.type == "aws_subnet"
  r.change.after.map_public_ip_on_launch == true
  msg := sprintf("[Rule 2] %v: map_public_ip_on_launch must be false.", [r.address])
}

# ---------- Rule 3: no SSH (22) from 0.0.0.0/0 in security group rules ----------
deny contains msg if {
  some r in plan.resource_changes
  r.mode == "managed"
  r.type == "aws_vpc_security_group_ingress_rule"
  r.change.after.cidr_ipv4 == "0.0.0.0/0"
  r.change.after.from_port <= 22
  r.change.after.to_port >= 22
  msg := sprintf("[Rule 3] %v: SSH (port 22) must not be open to 0.0.0.0/0.", [r.address])
}
