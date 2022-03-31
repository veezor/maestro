#!/bin/bash

set -eo pipefail

VALID_ARGS=$(getopt -o b:p:r: --long branch-name:,process-type:,repository-slug: -n 'provision.sh' -- "$@")
if [[ $? -ne 0 ]]; then
	exit 1;
fi

eval set -- "$VALID_ARGS"
while [ : ]; do
	case "$1" in
		-b | --branch-name)
			provision_branch_name=$2
			#echo "Branch name is '$2'"
			shift 2
			;;
		-p | --process-type)
			provision_process_type=$2
			#echo "Process Type is '$2'"
			shift 2
			;;
		-r | --repository-slug)
			provision_repository_slug=$2
			#echo "Repository slug is '$2'"
			shift 2
			;;
		--) shift;
		    break
		    ;;
    esac
done

if [ -z "$provision_branch_name" ]; then
	echo "Error: Missing required parameter --branch-name"
	exit 1
fi

if [ -z "$provision_process_type" ]; then
	echo "Error: Missing required parameter --process-type"
	exit 1
fi

if [ -z "$provision_repository_slug" ]; then
	echo "Error: Missing required parameter --repository-slug"
	exit 1
fi

provision_log_group_name="/ecs/$provision_repository_slug-$provision_branch_name-$provision_process_type"
provision_log_group_exists=$(aws logs describe-log-groups --log-group-name-prefix $provision_log_group_name | jq '.logGroups | length')
if [ "$provision_log_group_exists" -eq "0" ]; then
	provision_log_group_output=$(aws logs create-log-group \
	--log-group-name $provision_log_group_name \
	--tags $WORKLOAD_RESOURCE_TAGS)
	echo "----> Created missing log group for $provision_process_type"
fi

provision_json_workload_resource_tags=$(jq --raw-input --raw-output '[ split(",") | .[] | "Key=" + split("=")[0] + ",Value=" + split("=")[1] ] | join(" ")' <<<"$WORKLOAD_RESOURCE_TAGS")
if [ "$provision_process_type" = "web" ]; then
    provision_alb_name=$provision_repository_slug-$provision_branch_name
    provision_alb_exists=$(aws elbv2 describe-load-balancers --name ${provision_alb_name:0:32} || echo false)
    if [ "$provision_alb_exists" = false ]; then
        if [ -z "$ALB_SCHEME" ]; then
            ALB_SCHEME=internet-facing 
        fi
        provision_alb_subnets=$(jq --raw-input --raw-output 'split(",") | join(" ")' <<<"$ALB_SUBNETS")
        provision_alb_security_groups=$(jq --raw-input --raw-output 'split(",") | join(" ")' <<<"$ALB_SECURITY_GROUPS")
        provision_alb_create_output=$(aws elbv2 create-load-balancer \
        --name ${provision_alb_name:0:32} \
        --subnets $provision_alb_subnets \
        --security-groups $provision_alb_security_groups \
        --scheme $ALB_SCHEME \
        --tags $provision_json_workload_resource_tags \
        --type application)
        echo "----> Provisioned ALB for $provision_process_type"
        provision_alb_arn=$(jq --raw-output '.LoadBalancers[0].LoadBalancerArn' <<<$provision_alb_create_output)
    else
        provision_alb_arn=$(jq --raw-output '.LoadBalancers[0].LoadBalancerArn' <<<$provision_alb_exists)
    fi
    provision_tg_name=$provision_repository_slug-$provision_branch_name
    provision_tg_exists=$(aws elbv2 describe-target-groups --name ${provision_alb_name:0:32} || echo false)
    if [ "$provision_tg_exists" = false ]; then
        if [ -z "$PORT" ]; then
            # TODO: remember to load it from SM
            PORT=3000
        fi
        provision_tg_create_output=$(aws elbv2 create-target-group \
        --name ${provision_tg_name:0:32} \
        --protocol HTTP \
        --port $PORT \
        --vpc-id $WORKLOAD_VPC_ID \
        --target-type ip \
        --tags $provision_json_workload_resource_tags)
        echo "----> Provisioning Target Group for $provision_process_type"
        provision_target_group_arn=$(jq --raw-output '.TargetGroups[0].TargetGroupArn' <<<$provision_tg_create_output)
    else
        provision_target_group_arn=$(jq --raw-output '.TargetGroups[0].TargetGroupArn' <<<$provision_tg_exists)
    fi
    echo $provision_target_group_arn > .tgarn
    provision_listener_exists=$(aws elbv2 describe-listeners --load-balancer-arn $provision_alb_arn | jq '.Listeners | length')
    if [ "$provision_listener_exists" -eq "0" ]; then
        provision_listener_create_output=$(aws elbv2 create-listener \
        --load-balancer-arn $provision_alb_arn \
        --protocol HTTP \
        --port 80 \
        --tags $provision_json_workload_resource_tags \
        --default-actions Type=forward,TargetGroupArn=$provision_target_group_arn)
    fi
fi