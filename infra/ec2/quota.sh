#!/usr/bin/env bash
# Pre-flight checks for a topology on EC2: every instance type is offered in its region, and the On-Demand
# standard-instance vCPU quota (L-1216C47A) leaves room for the instances. Exit 1 when a check fails. UNTESTED.
#
#   quota.sh TOPOLOGY --run RUN [--location ROLE=REGION]... [--dry-run]

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

main() {
  local region roles role types need limit used offered t fail=0
  while [ $# -gt 0 ]; do common_arg "$@"; shift "$SHIFT"; done
  finish_common
  for region in $(for role in $(region_roles); do region_of "$role"; done | sort -u); do
    roles=$(for role in $(region_roles); do [ "$(region_of "$role")" = "$region" ] && echo "$role"; done)
    types=$(for role in $roles; do for n in $(vm_names "$role"); do vm_type "$n"; done; done)
    if dry; then
      aws_read "$region" ec2 describe-instance-type-offerings --location-type region
      aws_read "$region" service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A
      continue
    fi
    offered=$(aws --region "$region" ec2 describe-instance-type-offerings --location-type region \
      --filters "Name=instance-type,Values=$(echo "$types" | sort -u | tr '\n' ',' | sed 's/,$//')" \
      --query 'InstanceTypeOfferings[].InstanceType' --output text)
    for t in $(echo "$types" | sort -u); do
      echo "$offered" | tr '\t' '\n' | grep -qx "$t" || { echo "FAIL $region: $t not offered"; fail=1; }
    done
    # shellcheck disable=SC2046
    need=$(aws --region "$region" ec2 describe-instance-types --instance-types $(echo "$types" | sort -u) -o json \
      | jq --argjson list "$(echo "$types" | jq -R . | jq -s .)" \
        '[.InstanceTypes[] | {(.InstanceType): .VCpuInfo.DefaultVCpus}] | add as $v | [$list[] | $v[.]] | add')
    limit=$(aws --region "$region" service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
      --query Quota.Value --output text)
    used=$(aws --region "$region" ec2 describe-instances --filters Name=instance-state-name,Values=pending,running -o json \
      | jq '[.Reservations[].Instances[] | .CpuOptions.CoreCount * .CpuOptions.ThreadsPerCore] | add // 0')
    if [ "$(jq -n --argjson l "${limit%.*}" --argjson u "$used" --argjson n "$need" '$l - $u >= $n')" = true ]; then
      echo "ok   $region: On-Demand standard vCPUs $used/${limit%.*} used, need $need"
    else
      echo "FAIL $region: On-Demand standard vCPUs $used/${limit%.*} used, need $need"; fail=1
    fi
  done
  exit "$fail"
}

main "$@"
