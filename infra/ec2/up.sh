#!/usr/bin/env bash
# Deploy a topology on EC2, mirroring infra/azure/up.sh. UNTESTED: the Azure scripts are the tested path.
#
#   up.sh TOPOLOGY --run RUN [--location ROLE=REGION]... [--step S]... [--dry-run]
#
# Steps (all by default, each idempotent through work/RUN/ec2-ROLE.json):
#   network    per region: VPC with the topology prefix, one public subnet in an availability zone that offers
#              every instance type of the region (BENCH_EC2_AZ_<ROLE> overrides), internet gateway and route,
#              security group (SSH from this machine, everything from the topology's prefixes), cluster
#              placement group when "ppg" is true, and the SSH key pair
#   vms        instances (Ubuntu 24.04, type from ec2_type or BENCH_EC2_TYPE_<NAME>), the first of each placement
#              group alone; waits until SSH answers and cloud-init finished. Instance-store NVMe is mounted later
#              by scripts/remote/nvme.sh
#   lb         Network Load Balancers ("lbs"): TCP listeners per port with TCP health checks, instance targets
#              (client IP preserved), listener idle timeout BENCH_LB_IDLE_SECONDS (6000 s = 100 min); public ones
#              admit the "clients" VMs' public IPs (and BENCH_CLIENT_CIDRS) in the security group
#   peer       inter-region VPC peering for every pair in "peerings", with routes both ways
#   inventory  work/RUN/hosts.json (SSH user ubuntu)

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

STEPS="network vms lb peer inventory"

pick_az() {
  local role="$1" region="$2" types var az
  var="BENCH_EC2_AZ_$(printf '%s' "$role" | tr 'a-z-' 'A-Z_')"
  if [ -n "${!var:-}" ]; then echo "${!var}"; return; fi
  if dry; then echo "${region}a"; return; fi
  types=$(for n in $(vm_names "$role"); do vm_type "$n"; done | sort -u | tr '\n' ',' | sed 's/,$//')
  az=$(aws --region "$region" ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$types" -o json \
    | jq -r --argjson n "$(echo "$types" | tr ',' '\n' | wc -l | tr -d ' ')" '
      .InstanceTypeOfferings | group_by(.Location) | map(select(length == $n)) | .[0][0].Location // empty')
  [ -n "$az" ] || die "no availability zone in $region offers all of $types"
  echo "$az"
}

step_network() {
  local role region prefix vpc igw subnet rtb sg pg cidr p key az
  key=$(ssh_key)
  for role in $(region_roles); do
    region=$(region_of "$role"); prefix=$(region_prefix "$role")
    vpc=$(state_get "$role" vpc)
    if [ -z "$vpc" ]; then
      say "$region: VPC $prefix"
      vpc=$(aws_do "$region" ec2 create-vpc --cidr-block "$prefix" --tag-specifications "$(tag_spec vpc "$role")" \
        --query Vpc.VpcId --output text)
      aws_do "$region" ec2 wait vpc-available --vpc-ids "$vpc" > /dev/null
      aws_do "$region" ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames '{"Value":true}' > /dev/null
      state_set "$role" vpc "$vpc"
    fi
    igw=$(state_get "$role" igw)
    if [ -z "$igw" ]; then
      igw=$(aws_do "$region" ec2 create-internet-gateway --tag-specifications "$(tag_spec internet-gateway "$role")" \
        --query InternetGateway.InternetGatewayId --output text)
      aws_do "$region" ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" > /dev/null
      state_set "$role" igw "$igw"
    fi
    subnet=$(state_get "$role" subnet)
    if [ -z "$subnet" ]; then
      az=$(pick_az "$role" "$region")
      subnet=$(aws_do "$region" ec2 create-subnet --vpc-id "$vpc" --cidr-block "$(subnet_prefix "$prefix")" \
        --availability-zone "$az" --tag-specifications "$(tag_spec subnet "$role")" --query Subnet.SubnetId --output text)
      aws_do "$region" ec2 modify-subnet-attribute --subnet-id "$subnet" --map-public-ip-on-launch > /dev/null
      state_set "$role" subnet "$subnet"; state_set "$role" az "$az"
    fi
    rtb=$(state_get "$role" rtb)
    if [ -z "$rtb" ]; then
      rtb=$(aws_do "$region" ec2 create-route-table --vpc-id "$vpc" --tag-specifications "$(tag_spec route-table "$role")" \
        --query RouteTable.RouteTableId --output text)
      aws_do "$region" ec2 create-route --route-table-id "$rtb" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" > /dev/null
      aws_do "$region" ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$subnet" > /dev/null
      state_set "$role" rtb "$rtb"
    fi
    sg=$(state_get "$role" sg)
    if [ -z "$sg" ]; then
      sg=$(aws_do "$region" ec2 create-security-group --group-name "$RUN-$role" --description "bench $RUN $role" \
        --vpc-id "$vpc" --tag-specifications "$(tag_spec security-group "$role")" --query GroupId --output text)
      cidr=$(operator_cidr)
      aws_do "$region" ec2 authorize-security-group-ingress --group-id "$sg" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$cidr,Description=operator}]" > /dev/null
      for p in $(topo '[.regions[].prefix] | unique[]'); do
        aws_do "$region" ec2 authorize-security-group-ingress --group-id "$sg" \
          --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=$p,Description=lab}]" > /dev/null
      done
      state_set "$role" sg "$sg"
    fi
    if [ "$(region_ppg "$role")" = true ] && [ -z "$(state_get "$role" pg)" ]; then
      pg="$RUN-$role"
      aws_do "$region" ec2 create-placement-group --group-name "$pg" --strategy cluster \
        --tag-specifications "$(tag_spec placement-group "$role")" > /dev/null
      state_set "$role" pg "$pg"
    fi
    if [ -z "$(state_get "$role" key)" ]; then
      aws_do "$region" ec2 import-key-pair --key-name "$RUN" --public-key-material "fileb://$key.pub" > /dev/null
      state_set "$role" key "$RUN"
    fi
    say "$region: network ready ($vpc)"
  done
}

instance_id() {
  local region="$1" name="$2" id
  id=$(aws_read "$region" ec2 describe-instances --filters "Name=tag:bench-run,Values=$RUN" "Name=tag:bench-name,Values=$name" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[0].InstanceId' \
    --output text)
  [ "$id" = None ] && id=""
  echo "$id"
}

create_instance() {
  local name="$1" role region ami id placement=() ci
  role=$(vm_field "$name" region); region=$(region_of "$role")
  id=$(instance_id "$region" "$name")
  if [ -n "$id" ]; then say "$name exists ($id)"; return 0; fi
  ami=$(aws_read "$region" ssm get-parameter --name "$BENCH_EC2_AMI_PARAM" --query Parameter.Value --output text)
  ami="${ami:-ami-dry}"
  [ -n "$(state_get "$role" pg)" ] && placement=(--placement "GroupName=$(state_get "$role" pg)")
  ci="$(run_dir)/$name.cloud-init"
  printf '#!/bin/bash\ntouch /var/lib/bench-ready\n' > "$ci"
  say "creating $name ($(vm_type "$name")) in $region"
  aws_do "$region" ec2 run-instances --image-id "$ami" --instance-type "$(vm_type "$name")" --key-name "$RUN" \
    --subnet-id "$(state_get "$role" subnet)" --security-group-ids "$(state_get "$role" sg)" ${placement[@]+"${placement[@]}"} \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$(vm_field "$name" disk),VolumeType=gp3,DeleteOnTermination=true}" \
    --user-data "file://$ci" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=bench-run,Value=$RUN},{Key=bench-name,Value=$name},{Key=bench-role,Value=$(vm_field "$name" role)},{Key=Name,Value=$RUN-$name}]" \
    --query 'Instances[0].InstanceId' --output text > /dev/null
}

wait_instance() {
  local name="$1" region ip key state
  region=$(region_of "$(vm_field "$name" region)")
  if dry; then return 0; fi
  aws ec2 wait instance-running --region "$region" --instance-ids "$(instance_id "$region" "$name")"
  ip=$(aws --region "$region" ec2 describe-instances --instance-ids "$(instance_id "$region" "$name")" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  key=$(ssh_key)
  for _ in $(seq 1 90); do
    state=$(ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$(run_dir)/known_hosts" "$BENCH_EC2_USER@$ip" \
      'test -f /var/lib/bench-ready && echo ready || cloud-init status 2>/dev/null | sed -n "s/^status: //p"' 2> /dev/null || echo unreachable)
    case "$state" in ready|done) say "$name ready ($ip)"; return 0 ;; error) die "$name: cloud-init error" ;; esac
    sleep 10
  done
  die "$name not ready after 15 minutes"
}

step_vms() {
  local role name first pids=() pid failed=0
  for role in $(region_roles); do
    first=1
    for name in $(vm_names "$role"); do
      if [ "$first" = 1 ] && [ -n "$(state_get "$role" pg)" ]; then
        create_instance "$name"; wait_instance "$name"; first=0; continue
      fi
      create_instance "$name"
    done
  done
  for name in $(vm_names); do wait_instance "$name" & pids+=($!); done
  for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" || failed=1; done
  [ "$failed" = 0 ] || die "some instances did not become ready"
}

lb_json() { topo --arg n "$1" '.lbs[] | select(.name == $n)'; }

public_ip_of() {
  local name="$1" region
  region=$(region_of "$(vm_field "$name" region)")
  if dry; then echo 198.51.100.7; return; fi
  aws --region "$region" ec2 describe-instances --instance-ids "$(instance_id "$region" "$name")" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

step_lb() {
  local name kind role region lbname arn tg port vpc targets="" b sources ip fe
  for name in $(topo '.lbs[].name'); do
    kind=$(lb_json "$name" | jq -r .kind); role=$(lb_json "$name" | jq -r .region)
    region=$(region_of "$role"); vpc=$(state_get "$role" vpc); lbname="$RUN-$name"
    arn=$(state_get "$role" "lb-$name")
    if [ -z "$arn" ]; then
      say "$region: NLB $lbname ($kind)"
      arn=$(aws_do "$region" elbv2 create-load-balancer --name "$lbname" --type network \
        --scheme "$([ "$kind" = public ] && echo internet-facing || echo internal)" \
        --subnets "$(state_get "$role" subnet)" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
      state_set "$role" "lb-$name" "$arn"
    fi
    for b in $(lb_json "$name" | jq -r '.backends[]'); do targets="$targets Id=$(instance_id "$region" "$b")"; done
    for port in $(lb_json "$name" | jq -r '.ports[]'); do
      tg=$(state_get "$role" "tg-$name-$port")
      if [ -z "$tg" ]; then
        tg=$(aws_do "$region" elbv2 create-target-group --name "$(printf '%s' "$RUN-$name-$port" | cut -c1-32)" \
          --protocol TCP --port "$port" --vpc-id "$vpc" --target-type instance --health-check-protocol TCP \
          --health-check-interval-seconds 10 --query 'TargetGroups[0].TargetGroupArn' --output text)
        state_set "$role" "tg-$name-$port" "$tg"
        local listener
        listener=$(aws_do "$region" elbv2 create-listener --load-balancer-arn "$arn" --protocol TCP --port "$port" \
          --default-actions "Type=forward,TargetGroupArn=$tg" --query 'Listeners[0].ListenerArn' --output text)
        aws_do "$region" elbv2 modify-listener-attributes --listener-arn "$listener" \
          --attributes "Key=tcp.idle_timeout.seconds,Value=$BENCH_LB_IDLE_SECONDS" > /dev/null
      fi
      # shellcheck disable=SC2086
      aws_do "$region" elbv2 register-targets --target-group-arn "$tg" --targets $targets > /dev/null
    done
    targets=""
    if [ "$kind" = public ]; then
      sources="${BENCH_CLIENT_CIDRS:-}"
      for b in $(lb_json "$name" | jq -r '.clients // [] | .[]'); do sources="$sources $(public_ip_of "$b")/32"; done
      for ip in $sources; do
        for port in $(lb_json "$name" | jq -r '.ports[]'); do
          aws_do "$region" ec2 authorize-security-group-ingress --group-id "$(state_get "$role" sg)" \
            --ip-permissions "IpProtocol=tcp,FromPort=$port,ToPort=$port,IpRanges=[{CidrIp=$ip,Description=clients}]" \
            > /dev/null 2>&1 || true
        done
      done
      fe=$(aws_read "$region" ec2 describe-network-interfaces --filters "Name=description,Values=ELB net/$lbname/*" \
        --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
    else
      fe=$(aws_read "$region" ec2 describe-network-interfaces --filters "Name=description,Values=ELB net/$lbname/*" \
        --query 'NetworkInterfaces[0].PrivateIpAddress' --output text)
    fi
    mkdir -p "$(run_dir)/lb"
    lb_json "$name" | jq --arg ip "${fe:-192.0.2.10}" '{name, kind, region, ports, backends, ip: $ip}' > "$(run_dir)/lb/$name.json"
  done
}

step_peer() {
  local pair a b ra rb pcx
  for pair in $(topo '.peerings[] | join(":")'); do
    a="${pair%%:*}"; b="${pair#*:}"; ra=$(region_of "$a"); rb=$(region_of "$b")
    pcx=$(state_get "$a" "pcx-$b")
    if [ -z "$pcx" ]; then
      say "peering $a ($ra) with $b ($rb)"
      pcx=$(aws_do "$ra" ec2 create-vpc-peering-connection --vpc-id "$(state_get "$a" vpc)" \
        --peer-vpc-id "$(state_get "$b" vpc)" --peer-region "$rb" \
        --query VpcPeeringConnection.VpcPeeringConnectionId --output text)
      state_set "$a" "pcx-$b" "$pcx"
      dry || sleep 10
      aws_do "$rb" ec2 accept-vpc-peering-connection --vpc-peering-connection-id "$pcx" > /dev/null
      aws_do "$ra" ec2 create-route --route-table-id "$(state_get "$a" rtb)" \
        --destination-cidr-block "$(region_prefix "$b")" --vpc-peering-connection-id "$pcx" > /dev/null
      aws_do "$rb" ec2 create-route --route-table-id "$(state_get "$b" rtb)" \
        --destination-cidr-block "$(region_prefix "$a")" --vpc-peering-connection-id "$pcx" > /dev/null
    fi
  done
}

step_inventory() {
  local role region vms="[]" lbs="[]" f out
  out="$(run_dir)/hosts.json"
  for role in $(region_roles); do
    region=$(region_of "$role")
    if dry; then
      vms=$(jq -c --arg r "$role" --argjson t "$(cat "$TOPOLOGY")" '. + [$t.vms | to_entries[] | select(.value.region == $r)
        | {name: .value.name, private: "10.0.0.\(.key + 4)", public: "192.0.2.\(.key + 4)"}]' <<< "$vms")
      continue
    fi
    vms=$(jq -c --argjson add "$(aws --region "$region" ec2 describe-instances \
      --filters "Name=tag:bench-run,Values=$RUN" "Name=instance-state-name,Values=running" -o json \
      | jq '[.Reservations[].Instances[] | {name: ((.Tags // [])[] | select(.Key == "bench-name") | .Value),
             private: .PrivateIpAddress, public: .PublicIpAddress}]')" '. + $add' <<< "$vms")
  done
  for f in "$(run_dir)"/lb/*.json; do [ -f "$f" ] && lbs=$(jq -c --slurpfile l "$f" '. + $l' <<< "$lbs"); done
  jq -n --arg run "$RUN" --argjson vms "$vms" --argjson lbs "$lbs" --arg user "$BENCH_EC2_USER" \
    --arg key "$(ssh_key)" --arg known "$(run_dir)/known_hosts" --slurpfile t "$TOPOLOGY" '
    {run: $run, track: $t[0].track, provider: "ec2", ssh: {user: $user, key: $key, known_hosts: $known},
     regions: ($t[0].regions | map_values({location: .ec2_region})), targets: ($t[0].targets // {}),
     hosts: [$t[0].vms[] as $v | ($vms[] | select(.name == $v.name)) as $m
       | {name: $v.name, role: $v.role, region: $v.region, size: $v.ec2_type, nvme: ($v.nvme // false),
          private_ip: $m.private, public_ip: $m.public, provision: ($v.provision // [])}],
     lbs: $lbs}' > "$out"
  [ "$(jq '.hosts | length' "$out")" = "$(topo '.vms | length')" ] || die "some instances are missing from the inventory"
  say "inventory: $out"
  echo "$out"
}

main() {
  local selected="" s
  while [ $# -gt 0 ]; do
    case "$1" in
      --step) selected="$selected ${2:?}"; shift 2 ;;
      *) common_arg "$@"; shift "$SHIFT" ;;
    esac
  done
  finish_common
  for s in $STEPS; do
    if [ -n "$selected" ]; then case " $selected " in *" $s "*) ;; *) continue ;; esac; fi
    if [ "$s" = lb ] && [ "$(topo '.lbs | length')" = 0 ]; then continue; fi
    if [ "$s" = peer ] && [ "$(topo '.peerings | length')" = 0 ]; then continue; fi
    "step_$s"
  done
}

main "$@"
