#!/bin/bash

set -eo pipefail
set -x

if [ $MAESTRO_DEBUG == "true" ]; then
    set -x
fi

VALID_ARGS=$(getopt -o b:p:r:i: --long branch-name:,process-type:,repository-slug:,cluster-id: -n 'provision.sh' -- "$@")
if [[ $? -ne 0 ]]; then
	exit 1;
fi

eval set -- "$VALID_ARGS"
while [ : ]; do
	case "$1" in
		-b | --branch-name)
			provision_branch_name=$2
			shift 2
			;;
		-p | --process-type)
			provision_process_type=$2
			shift 2
			;;
		-r | --repository-slug)
			provision_repository_slug=$2
			shift 2
			;;
        -i | --cluster-id)
            provision_cluster_id=$2
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

if [ -z "$provision_cluster_id" ]; then
	echo "Error: Missing required parameter --cluster-id"
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

provision_json_workload_resource_tags=$(jq --raw-input --raw-output '[ split(",") | .[] | "key=" + split("=")[0] + ",value=" + split("=")[1] ] | join(" ")' <<<"$WORKLOAD_RESOURCE_TAGS")
provision_json_workload_resource_tags_captalized=$(jq --raw-input --raw-output '[ split(",") | .[] | "Key=" + split("=")[0] + ",Value=" + split("=")[1] ] | join(" ")' <<<"$WORKLOAD_RESOURCE_TAGS")

provision_cluster_status=$(aws ecs describe-clusters \
--cluster $provision_cluster_id --query 'clusters[?status==`INACTIVE`].status' --output text
)
provision_cluster_failure_reason=$(aws ecs describe-clusters \
--cluster $provision_cluster_id --query 'failures[?reason==`MISSING`].reason' --output text
)
if [ "$provision_cluster_status" == "INACTIVE" ] || [ ! -z "$provision_cluster_failure_reason" ]; then
	provision_create_cluster=$(aws ecs create-cluster \
	--cluster-name $provision_cluster_id \
	--tags $provision_json_workload_resource_tags \
	--capacity-provider FARGATE FARGATE_SPOT EC2 \
	--default-capacity-provider-strategy capacityProvider=FARGATE_SPOT,weight=1
	)
	echo "----> First deployment detected. Provisioning cluster $provision_cluster_id"
fi

provision_json_workload_resource_tags=$(jq --raw-input --raw-output '[ split(",") | .[] | "Key=" + split("=")[0] + ",Value=" + split("=")[1] ] | join(" ")' <<<"$WORKLOAD_RESOURCE_TAGS")
if [ "$provision_process_type" = "web" ]; then
    if [ ! -z "$ALB_NAME_OVERRIDE" ]; then
        provision_alb_name=$ALB_NAME_OVERRIDE
    else
        provision_alb_name=$provision_repository_slug-$provision_branch_name
    fi
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
    provision_json_workload_resource_tags=$(jq --raw-input --raw-output '[ split(",") | .[] | "Key=" + split("=")[0] + ",Value=" + split("=")[1] ] | join(" ")' <<<"$WORKLOAD_RESOURCE_TAGS")
    provision_tg_name=$provision_repository_slug-$provision_branch_name
    provision_tg_exists=$(aws elbv2 describe-target-groups --name ${provision_tg_name:0:32} || echo false)
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

if [[ "$provision_process_type" =~ ^web[1-9] ]]; then
    provision_alb_name=$provision_repository_slug-$provision_branch_name
    provision_alb_exists=$(aws elbv2 describe-load-balancers --name ${provision_alb_name:0:32} || echo false)
    provision_alb_arn=$(jq --raw-output '.LoadBalancers[].LoadBalancerArn' <<<$provision_alb_exists)
    if [ "$provision_alb_exists" = false ]; then
        echo "----> Error: The Procfile order needs to 'WEB' process be the first."
        exit 1
    fi
    provision_json_workload_resource_tags=$(jq --raw-input --raw-output '[ split(",") | .[] | "Key=" + split("=")[0] + ",Value=" + split("=")[1] ] | join(" ")' <<<"$WORKLOAD_RESOURCE_TAGS")
    provision_tg_name=$provision_process_type-$provision_repository_slug-$provision_branch_name
    provision_tg_exists=$(aws elbv2 describe-target-groups --name ${provision_tg_name:0:32} || echo false)
    provision_tg_port=$(aws secretsmanager get-secret-value --secret-id $provision_branch_name/$provision_repository_slug | jq --raw-output '.SecretString' | jq -r .PORT${provision_process_type^^} || echo false)
    if [ $provision_tg_port = false ]; then
        echo "----> Error: Port not found in secretsmanager. Add the variable PORT${provision_process_type^^} for the new process to secretsmanager."
        exit 1
    fi
    if [ "$provision_tg_exists" = false ]; then
        provision_tg_create_output=$(aws elbv2 create-target-group \
        --name ${provision_tg_name:0:32} \
        --protocol HTTP \
        --port $provision_tg_port \
        --vpc-id $WORKLOAD_VPC_ID \
        --target-type ip \
        --tags $provision_json_workload_resource_tags)
        echo "----> Provisioning Target Group for $provision_process_type"
        provision_target_group_arn=$(jq --raw-output '.TargetGroups[0].TargetGroupArn' <<<$provision_tg_create_output)
    else
        provision_target_group_arn=$(jq --raw-output '.TargetGroups[0].TargetGroupArn' <<<$provision_tg_exists)
    fi
    echo $provision_target_group_arn > .tgarn
    echo "[{"Field": "path-pattern", "PathPatternConfig": {"Values": ["/text/*"]}}]" > listener-conditions.json
    provision_listener_exists=$(aws elbv2 describe-listeners --load-balancer-arn $provision_alb_arn | jq --raw-output '.Listeners[0].ListenerArn' || echo false)
    if [ "$provision_listener_exists" != false ]; then
        provision_listener_rule_create_output=$(aws elbv2 create-rule \
        --listener-arn $provision_listener_exists \
        --priority 1 \
        --conditions file://listener-conditions.json \
        --actions Type=forward,TargetGroupArn=$provision_target_group_arn)
    fi
fi