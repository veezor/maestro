#!/bin/bash

set -eo pipefail

VALID_ARGS=$(getopt -o ac:e:f:i:n:p:st:u --long app-spec,use-secrets,container-name:,environment-variables:,family-name:,process-type:,image:,task-definition:,aws-sm-name:,aws-sm-arns -n 'render.sh' -- "$@")
if [[ $? -ne 0 ]]; then
	exit 1;
fi

eval set -- "$VALID_ARGS"
while [ : ]; do
	case "$1" in
		-a | --aws-sm-arns)
			render_aws_sm_arns=1
			#echo "AWS CodeBuild Role ARNs are on Secret Manager"
			shift 
			;;
		-c | --container-name)
			render_container_name=$2
			#echo "Container name is '$2'"
			shift 2
			;;
		-e | --environment-variables)
			render_environment_variables=$2
			#echo "Environment variables are '$2'"
			shift 2
			;;
		-f | --family-name)
			render_family_name=$2
			#echo "Family name is '$2'"
			shift 2
			;;
		-i | --image)
			render_image=$2
			#echo "Image is '$2'"
			shift 2
			;;
		-n | --aws-sm-name)
			render_aws_sm_name=$2
			#echo "AWS Secret Manager Name is '$2'"
			shift 2
			;;
		-p | --process-type)
			render_process_type=$2
			#echo "Process Type is '$2'"
			shift 2
			;;
		-s | --app-spec)
			render_app_spec=1
			#echo "Render the appspec.yml template"
			shift
			;;
		-t | --task-definition)
			render_task_definition=$2
			#echo "Task definition is '$2'"
			shift 2
			;;
		-u | --use-secrets)
			render_use_secrets=1
			#echo "We should use secrets as reference"
			shift
			;;
		--) shift;
		    break
		    ;;
    esac
done

if [ -z "$render_task_definition" ]; then
	echo "Error: Missing required parameter --task-definition"
	exit 1
fi

if [ -z "$render_container_name" ]; then
	echo "Error: Missing required parameter --container-name"
	exit 1
fi

if [ -z "$render_image" ]; then
	echo "Error: Missing required parameter --image"
	exit 1
fi

echo "----> Checking Task Definition file '$render_task_definition' exists"
if [ ! -f "$render_task_definition" ] || [ ! -s "$render_task_definition" ]; then
	echo "File $render_task_definition was not found or is empty! Creating one based on the standard template..."
    cp /templates/task-definition.json $render_task_definition
	cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"placeholder\") | .name=\"$render_container_name\")" $render_task_definition) > $render_task_definition
fi

echo "----> Checking Task Definition file '$render_task_definition' has valid JSON"
render_task_definition_contents=$(cat $render_task_definition)
if ! jq -e . >/dev/null 2>&1 <<<"$render_task_definition_contents"; then
    echo "Error: Failed to parse JSON, or got false/null"
	exit 1
fi

echo "----> Checking container definitions"
render_is_task_definition_array=$(jq -r '.containerDefinitions | if type=="array" then "true" else "false" end' $render_task_definition)
if [ "${render_is_task_definition_array}" == "false" ]; then
	echo "Error: containerDefinitions section does not exist or is not an array"
	exit 1
fi

echo "----> Looking for $render_container_name"
render_is_container_name_present=$(jq ".containerDefinitions[] | select(.name==\"$render_container_name\")" $render_task_definition)
if [ -z "$render_is_container_name_present" ]; then
	echo "Error: '$render_container_name' was not found on task definition"
	exit 1
fi

if [ ! -z "$render_process_type" ] && [ ! "$render_process_type" == "web" ]; then
	echo "----> Defining entrypoint for non-web process type $render_process_type"
	cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | .entryPoint[0] = \"$render_process_type\" | del(.portMappings))" $render_task_definition) > $render_task_definition
fi

if [ ! -z "$render_process_type" ] && [ "$render_process_type" == "scheduledtasks" ]; then
	echo "----> Defining launcher entrypoint for process type $render_process_type"
	cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | .entryPoint[0] = \"launcher\")" $render_task_definition) > $render_task_definition
fi

echo "----> Filling image with $render_image"
cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | . + {image: \"$render_image\"})" $render_task_definition) > $render_task_definition

render_process_parameters="$render_process_type\{([0-9]+);([0-9]+)\}"
if [[ $ECS_SERVICE_TASK_PROCESSES =~ $render_process_parameters ]]; then
	if [ ! -z ${BASH_REMATCH[1]} ]; then
		echo "----> Filling CPU with ${BASH_REMATCH[1]}"
		cat <<< $(jq ".cpu=\"${BASH_REMATCH[1]}\"" $render_task_definition) > $render_task_definition
	fi

	if [ ! -z ${BASH_REMATCH[2]} ]; then
		echo "----> Filling Memory with ${BASH_REMATCH[2]}"
		cat <<< $(jq ".memory=\"${BASH_REMATCH[2]}\"" $render_task_definition) > $render_task_definition
		cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | . + {memory: ${BASH_REMATCH[2]}})" $render_task_definition) > $render_task_definition
	fi
fi

if [ ! -z "ECS_EFS_VOLUMES" ]; then
	render_volume_parameters="^(.*):(.*)\{(.*)@(.*)\}$"
	for volume in ${ECS_EFS_VOLUMES//,/ }; do
		render_volume_encrypted="DISABLED"
		# TODO: in order to expand possibilities (like readonly) this regex must be reviewed
		if [[ $volume =~ $render_volume_parameters ]]; then
			if [ ! -z ${BASH_REMATCH[4]##*;} ]; then
				render_volume_encrypted="ENABLED"
			fi
			echo "----> Filling EFS Volume ${BASH_REMATCH[2]} as ${BASH_REMATCH[1]} on ${BASH_REMATCH[3]} with encryption $render_volume_encrypted"
			cat <<< $(jq ".volumes += [{ \"name\": \"${BASH_REMATCH[1]}\", \"efsVolumeConfiguration\": { \"fileSystemId\": \"${BASH_REMATCH[2]}\", \"rootDirectory\": \"${BASH_REMATCH[3]}\", \"transitEncryption\": \"$render_volume_encrypted\"} }]" $render_task_definition) > $render_task_definition
			echo "----> Filling container mount point for ${BASH_REMATCH[1]} at ${BASH_REMATCH[4]%;*}"
			cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | .mountPoints += [{ \"containerPath\": \"${BASH_REMATCH[4]%;*}\", \"sourceVolume\": \"${BASH_REMATCH[1]}\"}])" $render_task_definition) > $render_task_definition
		fi
	done
fi

if [ ! -z "$render_family_name" ]; then
	echo "----> Filling family with $render_family_name"
	cat <<< $(jq ".family=\"$render_family_name\"" $render_task_definition) > $render_task_definition

    echo "----> Filling container's AWS logs information"
	cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | . + {logConfiguration: {logDriver: \"awslogs\", options: {\"awslogs-group\": \"/ecs/$render_family_name\", \"awslogs-region\": \"$AWS_REGION\", \"awslogs-stream-prefix\": \"ecs\"}}})" $render_task_definition) > $render_task_definition
fi

if [ ! -z "$render_aws_sm_name" ]; then
	echo "----> Retrieving ENVs from AWS Secrets Manager"
	render_aws_secrets_manager_result=$(aws secretsmanager get-secret-value --secret-id $render_aws_sm_name)
	if [ ! -z "$render_use_secrets" ]; then
		echo "----> Rendering ENVs to be retrieved in runtime"
		render_secrets=$(echo $render_aws_secrets_manager_result | jq '[ . as $parent | .SecretString | fromjson | to_entries | .[] | { name: .key, valueFrom: ($parent.ARN + ":" + .key + "::") } ]')
		cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | . + {secrets: $render_secrets})" $render_task_definition) > $render_task_definition
	else
		echo "----> Rendering ENVs from Secret Manager in plain text"
		render_environment=$(echo $render_aws_secrets_manager_result | jq '[ .SecretString | fromjson | to_entries | .[] | { name: .key, value: .value } ]')
		cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | . + {environment: $render_environment})" $render_task_definition) > $render_task_definition
	fi

    if [ ! -z "$WORKLOAD_RESOURCE_TAGS" ]; then
		render_aws_ecs_json_tags=$(jq --raw-input 'split(",") | map({"key": split("=")[0], "value": split("=")[1]})' <<<"$WORKLOAD_RESOURCE_TAGS")
		echo "----> Filling ECS Task Definition Tags"
        cat <<< $(jq ".tags=$render_aws_ecs_json_tags" $render_task_definition) > $render_task_definition
	fi

	if [ ! -z "$render_aws_sm_arns" ]; then
		echo "----> Filling service roles ARNs"
		echo "         Task Role ARN: $ECS_TASK_ROLE_ARN"
		echo "         Exec Role ARN: $ECS_EXECUTION_ROLE_ARN"
		cat <<< $(jq ".taskRoleArn=\"$ECS_TASK_ROLE_ARN\" | .executionRoleArn=\"$ECS_EXECUTION_ROLE_ARN\"" $render_task_definition) > $render_task_definition
	fi
else
	if [ ! -z "$render_use_secrets" ] || [ ! -z "$render_aws_sm_arns" ]; then
		echo "Warning: Skipping Secret Manager tasks as --aws-sm-name was not defined"
	fi
fi
echo "----> Task Definition successfully rendered!"
if [ ! -z "$render_app_spec" ]; then
	echo "----> Rendering appspec.yaml"
	render_container_port=$(jq ".containerDefinitions[] | select(.name==\"$render_container_name\") | .portMappings[].containerPort" $render_task_definition)
	# TODO: transfer default appspec.yaml to templates folder 
	cat <<EOL >> appspec.yaml
version: 0.0
Resources:
- TargetService:
	Type: AWS::ECS::Service
	Properties:
		TaskDefinition: <TASK_DEFINITION>
		LoadBalancerInfo:
		ContainerName: "$render_container_name"
		ContainerPort: $render_container_port
EOL
	echo "----> AppSpec succesfully created!"
fi