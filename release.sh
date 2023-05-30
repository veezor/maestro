#!/bin/bash
set -x
set -eo pipefail

VALID_ARGS=$(getopt -o b:i:l:p:r: --long branch-name:,cluster-id:,image-name:,process-type:,repository-slug: -n 'release.sh' -- "$@")
if [[ $? -ne 0 ]]; then
	exit 1;
fi

eval set -- "$VALID_ARGS"
while [ : ]; do
	case "$1" in
		-b | --branch-name)
			release_branch_name=$2
			#echo "Branch name is '$2'"
			shift 2
			;;
		-i | --image-name)
			release_image_name=$2
			#echo "Image Name is '$2'"
			shift 2
			;;
		-l | --cluster-id)
			release_cluster_id=$2
			#echo "Cluster ID is '$2'"
			shift 2
			;;
		-p | --process-type)
			release_process_type=$2
			#echo "Process Type is '$2'"
			shift 2
			;;
		-r | --repository-slug)
			release_repository_slug=$2
			#echo "Repository slug is '$2'"
			shift 2
			;;
		--) shift;
		    break
		    ;;
    esac
done

if [ -z "$release_process_type" ]; then
	echo "Error: Missing required parameter --process-type"
	exit 1
fi

if [ -z "$release_repository_slug" ]; then
	echo "Error: Missing required parameter --repository-slug"
	exit 1
fi

if [ -z "$release_branch_name" ]; then
	echo "Error: Missing required parameter --branch-name"
	exit 1
fi

echo "----> Rendering Task definition for process: $release_process_type"
render.sh --task-definition task-definition-$release_process_type.json \
--container-name $release_repository_slug \
--image $release_image_name \
--process-type $release_process_type \
--family-name $release_repository_slug-$release_branch_name-$release_process_type \
--aws-sm-name $release_branch_name/$release_repository_slug \
--use-secrets \
--aws-sm-arns
release_json_workload_resource_tags=$(jq --raw-input --raw-output '[ split(",") | .[] | "key=" + split("=")[0] + ",value=" + split("=")[1] ] | join(" ")' <<<"$WORKLOAD_RESOURCE_TAGS")
echo "----> Updating Task Definition on ECS"
release_task_definition_output=$(aws ecs register-task-definition \
--tags $release_json_workload_resource_tags \
--cli-input-json file://task-definition-$release_process_type.json)
release_arn=$(jq --raw-output '.taskDefinition.taskDefinitionArn' <<<"$release_task_definition_output")
echo $release_arn > .releasearn
echo "----> Created release for $release_process_type process v${release_arn##*:}"

if [ "$release_process_type" == "release" ]; then
    echo "----> Running release process with docker run"
	docker pull $release_image_name 2> /dev/null
    docker run \
	--env-file .env \
	--rm \
	--entrypoint release \
	$release_image_name
    # release_subnets=$(jq --raw-input --raw-output 'split(",")' <<<"$ECS_SERVICE_SUBNETS")
    # release_security_groups=$(jq --raw-input --raw-output 'split(",")' <<<"$ECS_SERVICE_SECURITY_GROUPS")
	# release_task_arn=$(aws ecs run-task \
	# --cluster $release_cluster_id \
	# --task-definition $release_arn \
	# --launch-type FARGATE \
	# --network-configuration "awsvpcConfiguration={subnets=$release_subnets,securityGroups=$release_security_groups,assignPublicIp=DISABLED}" \
	# --query 'tasks[].taskArn' \
	# --output text | rev | cut -d'/' -f1 | rev)
	# echo "----> Running release process with task ARN: $release_task_arn"
    # aws ecs wait tasks-stopped \
	# --cluster $release_cluster_id \
	# --task $release_task_arn
	# ecs-cli logs \
	# --task-id $release_task_arn \
	# --cluster $release_cluster_id
	# release_task_exit_code=$(aws ecs describe-tasks \
	# --cluster $release_cluster_id \
	# --tasks $release_task_arn \
	# --query "tasks[0].containers[?name=='$release_repository_slug'].exitCode" \
	# --output text)
	# if [ "$release_task_exit_code" != "0" ]; then
	# 	echo "ERROR: Release process failed with exit code: $release_task_exit_code. Aborting release."
	# 	exit 1
	# fi
fi