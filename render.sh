#!/bin/bash

set -ex

VALID_ARGS=$(getopt -o ac:e:f:i:n:t:u --long use-secrets,container-name:,environment-variables:,family-name:,image:,task-definition:,aws-sm-name:,aws-sm-arns -n 'render' -- "$@")
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
	echo "Error: File $render_task_definition was not found or is empty!"
	exit 1
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

echo "----> Filling image with $render_image"
cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | . + {image: \"$render_image\"})" $render_task_definition) > $render_task_definition

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
		render_secrets=$(echo $render_aws_secrets_manager_result | jq '[ . as $parent | .SecretString | fromjson | del(.TASK_ROLE_ARN, .EXECUTION_ROLE_ARN) | to_entries | .[] | { name: .key, valueFrom: ($parent.ARN + ":" + .key + "::") } ]')
		cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | . + {secrets: $render_secrets})" $render_task_definition) > $render_task_definition
	else
		echo "----> Rendering ENVs from Secret Manager in plain text"
		render_environment=$(echo $render_aws_secrets_manager_result | jq '[ .SecretString | fromjson | del(.TASK_ROLE_ARN, .EXECUTION_ROLE_ARN) | to_entries | .[] | { name: .key, value: .value } ]')
		cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | . + {environment: $render_environment})" $render_task_definition) > $render_task_definition
	fi
	if [ ! -z "$render_aws_sm_arns" ]; then
		echo "----> Filling service roles ARNs"
		render_task_role_arn=$(echo $render_aws_secrets_manager_result | jq '.SecretString | fromjson | .TASK_ROLE_ARN')
		render_execution_role_arn=$(echo $render_aws_secrets_manager_result | jq '.SecretString | fromjson | .EXECUTION_ROLE_ARN')
		echo "         Task Role ARN: $render_task_role_arn"
		echo "         Exec Role ARN: $render_execution_role_arn"
		cat <<< $(jq ".taskRoleArn=$render_task_role_arn | .executionRoleArn=$render_execution_role_arn" $render_task_definition) > $render_task_definition
	fi
else
	if [ ! -z "$render_use_secrets" ] || [ ! -z "$render_aws_sm_arns" ]; then
		echo "Warning: Skipping Secret Manager tasks as --aws-sm-name was not defined"
	fi
fi
echo "----> Task Definition successfully rendered!"
render_container_port=$(jq ".containerDefinitions[] | select(.name==\"$render_container_name\") | .portMappings[].containerPort" $render_task_definition)
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
