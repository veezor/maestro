#!/bin/bash

set -eo pipefail

VALID_ARGS=$(getopt -o ci:p:r:s: --long create-service,cluster-id:,process-type:,repository-slug:,service-name: -n 'deploy.sh' -- "$@")
if [[ $? -ne 0 ]]; then
	exit 1;
fi

eval set -- "$VALID_ARGS"
while [ : ]; do
	case "$1" in
		-c | --create-service)
			deploy_create_service=1
			#echo "We should create a service"
			shift
			;;
        -i | --cluster-id)
            deploy_cluster_id=$2
            #echo "Cluster ID is '$2'"
            shift 2
            ;;
		-p | --process-type)
			deploy_process_type=$2
			#echo "Process Type is '$2'"
			shift 2
			;;
        -r | --repository-slug)
            deploy_repository_slug=$2
            #echo "Repository Slug is '$2'"
            shift 2
            ;;
		-s | --service-name)
			deploy_service_name=$2
			#echo "Service name is '$2'"
			shift 2
			;;
		--) shift;
		    break
		    ;;
    esac
done

if [ -z "$deploy_process_type" ]; then
	echo "Error: Missing required parameter --process-type"
	exit 1
fi

if [ -z "$deploy_cluster_id" ]; then
	echo "Error: Missing required parameter --cluster-id"
	exit 1
fi

if [ -z "$deploy_repository_slug" ]; then
	echo "Error: Missing required parameter --repository-slug"
	exit 1
fi

if [ -z "$deploy_service_name" ]; then
	echo "Error: Missing required parameter --service-name"
	exit 1
fi

if [ -z "$ECS_SERVICE_TASK_PROCESSES" ] || [[ $ECS_SERVICE_TASK_PROCESSES =~ $deploy_process_type ]]; then
    release_arn=$(cat .releasearn)
	provision_target_group_arn=$(cat .tgarn)
    deploy_desired_count=1
	deploy_desired_count_regex="$deploy_process_type:([0-9]+).*"
	if [[ $ECS_SERVICE_TASK_PROCESSES =~ $deploy_desired_count_regex ]]; then
		deploy_desired_count=${BASH_REMATCH[1]}
	fi

	if [ -z "$PORT" ]; then
		# TODO: remember to load it from SM
		PORT=3000
	fi
	deploy_json_workload_resource_tags=$(jq --raw-input --raw-output '[ split(",") | .[] | "key=" + split("=")[0] + ",value=" + split("=")[1] ] | join(" ")' <<<"$WORKLOAD_RESOURCE_TAGS")
    echo "----> Deploying service $deploy_process_type"
	if [ ! -z "$deploy_create_service" ]; then
		deploy_ecs_output=$(aws ecs create-service \
		--cluster $deploy_cluster_id \
		--service-name $deploy_service_name \
		--task-definition $release_arn \
		--launch-type FARGATE \
		--network-configuration "awsvpcConfiguration={subnets=[$ECS_SERVICE_SUBNETS],securityGroups=[$ECS_SERVICE_SECURITY_GROUPS]}" \
		--desired-count $deploy_desired_count \
		--enable-execute-command \
		--tags $deploy_json_workload_resource_tags \
        $( [ "$deploy_process_type" = "web" ] && echo "--load-balancers targetGroupArn=$provision_target_group_arn,containerName=$deploy_repository_slug,containerPort=$PORT")
		)
		echo "----> First deployment of $release_arn with $deploy_desired_count task(s) in progress on ECS..."
	else
		deploy_ecs_output=$(aws ecs update-service \
		--cluster $deploy_cluster_id \
		--service $deploy_service_name \
		--task-definition $release_arn \
		--network-configuration "awsvpcConfiguration={subnets=[$ECS_SERVICE_SUBNETS],securityGroups=[$ECS_SERVICE_SECURITY_GROUPS]}" \
		--enable-execute-command \
		--force-new-deployment \
		--desired-count $deploy_desired_count
		)
		echo "----> Rolling deployment of $release_arn with $deploy_desired_count task(s) in progress on ECS..."
	fi
fi