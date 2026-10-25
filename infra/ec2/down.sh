#!/usr/bin/env bash
# Tear down every EC2 resource of a topology run (found by the bench-run tag, so it also cleans up after a lost
# work/ directory). UNTESTED, like the rest of infra/ec2.
#
#   down.sh TOPOLOGY --run RUN [--location ROLE=REGION]... [--dry-run]

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

clean_region() {
  local region="$1" ids arn vpc id
  ids=$(aws_read "$region" ec2 describe-instances --filters "Name=tag:bench-run,Values=$RUN" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$ids" ]; then
    say "$region: terminating $ids"
    # shellcheck disable=SC2086
    aws_do "$region" ec2 terminate-instances --instance-ids $ids > /dev/null
    # shellcheck disable=SC2086
    aws_do "$region" ec2 wait instance-terminated --instance-ids $ids > /dev/null
  fi
  for arn in $(aws_read "$region" elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, '$RUN-')].LoadBalancerArn" --output text); do
    aws_do "$region" elbv2 delete-load-balancer --load-balancer-arn "$arn" > /dev/null
    aws_do "$region" elbv2 wait load-balancers-deleted --load-balancer-arns "$arn" > /dev/null
  done
  for arn in $(aws_read "$region" elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName, '$RUN-')].TargetGroupArn" --output text); do
    aws_do "$region" elbv2 delete-target-group --target-group-arn "$arn" > /dev/null
  done
  for id in $(aws_read "$region" ec2 describe-vpc-peering-connections --filters "Name=status-code,Values=active,pending-acceptance" \
      --query "VpcPeeringConnections[?contains(['$(vpcs_csv "$region")'], RequesterVpcInfo.VpcId) || contains(['$(vpcs_csv "$region")'], AccepterVpcInfo.VpcId)].VpcPeeringConnectionId" --output text); do
    aws_do "$region" ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$id" > /dev/null || true
  done
  for id in $(aws_read "$region" ec2 describe-placement-groups --filters "Name=tag:bench-run,Values=$RUN" --query 'PlacementGroups[].GroupName' --output text); do
    aws_do "$region" ec2 delete-placement-group --group-name "$id" > /dev/null
  done
  for vpc in $(aws_read "$region" ec2 describe-vpcs --filters "Name=tag:bench-run,Values=$RUN" --query 'Vpcs[].VpcId' --output text); do
    for id in $(aws_read "$region" ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
      aws_do "$region" ec2 delete-security-group --group-id "$id" > /dev/null
    done
    for id in $(aws_read "$region" ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do
      aws_do "$region" ec2 delete-subnet --subnet-id "$id" > /dev/null
    done
    for id in $(aws_read "$region" ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
      aws_do "$region" ec2 delete-route-table --route-table-id "$id" > /dev/null
    done
    for id in $(aws_read "$region" ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' --output text); do
      aws_do "$region" ec2 detach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc" > /dev/null
      aws_do "$region" ec2 delete-internet-gateway --internet-gateway-id "$id" > /dev/null
    done
    aws_do "$region" ec2 delete-vpc --vpc-id "$vpc" > /dev/null
  done
  aws_do "$region" ec2 delete-key-pair --key-name "$RUN" > /dev/null || true
}

vpcs_csv() {
  aws_read "$1" ec2 describe-vpcs --filters "Name=tag:bench-run,Values=$RUN" --query 'Vpcs[].VpcId' --output text | sed "s/[[:space:]]\{1,\}/','/g"
}

main() {
  local role region done_regions=""
  while [ $# -gt 0 ]; do common_arg "$@"; shift "$SHIFT"; done
  finish_common
  for role in $(region_roles); do
    region=$(region_of "$role")
    case " $done_regions " in *" $region "*) continue ;; esac
    clean_region "$region"
    done_regions="$done_regions $region"
  done
  rm -f "$(run_dir)"/ec2-*.json "$(run_dir)"/lb/*.json
  [ -f "$(run_dir)/hosts.json" ] && mv "$(run_dir)/hosts.json" "$(run_dir)/hosts.json.down"
  say "run $RUN deleted"
}

main "$@"
