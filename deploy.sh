#!/bin/bash

set -eo pipefail

VALID_ARGS=$(getopt -o a:ci:p:r:s: --long account-id:,create-service,cluster-id:,process-type:,repository-slug:,service-name:,security-group-name: -n 'deploy.sh' -- "$@")
if [[ $? -ne 0 ]]; then
	exit 1;
fi

eval set -- "$VALID_ARGS"
while [ : ]; do
	case "$1" in
        -a | --account-id)
            deploy_account_id=$2
            #echo "Account ID is '$2'"
            shift 2
            ;;
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
		-g | --security-group-name)
			deploy_security_group_name=$2
			#echo "Security group name is '$2'"
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

if [ -z "$deploy_security_group_name" ]; then
	echo "Error: Missing required parameter --security-group-name"
	exit 1
fi

release_arn=$(cat .releasearn)
if [[ $deploy_process_type != "scheduledtasks" && ( -z "$ECS_SERVICE_TASK_PROCESSES" || $ECS_SERVICE_TASK_PROCESSES =~ $deploy_process_type ) ]]; then
	provision_target_group_arn=$(cat .tgarn)
    deploy_desired_count=1
	deploy_autoscaling_policies="cpu=55"
	deploy_desired_count_regex="$deploy_process_type[{};0-9]{0,}:([0-9]+)-{0,}([0-9]{0,})\[{0,}([;=0-9a-z]{0,})\]{0,}"
	if [[ $ECS_SERVICE_TASK_PROCESSES =~ $deploy_desired_count_regex ]]; then
		deploy_desired_count=${BASH_REMATCH[1]}
		deploy_max_autoscaling_count=${BASH_REMATCH[2]}
		deploy_autoscaling_policies=${BASH_REMATCH[3]}
	fi

	if [ -z "$PORT" ]; then
		# TODO: remember to load it from SM
		PORT=3000
	fi
	deploy_json_workload_resource_tags=$(jq --raw-input --raw-output '[ split(",") | .[] | "key=" + split("=")[0] + ",value=" + split("=")[1] ] | join(" ")' <<<"$WORKLOAD_RESOURCE_TAGS")
	echo "----> Deploying service $deploy_process_type"
	if [ "$deploy_process_type" = "web" ]; then
		deploy_service_security_group_id=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$deploy_security_group_name | jq --raw-output '.SecurityGroups[0].GroupId')
	fi
	if [ ! -z "$deploy_create_service" ]; then
		deploy_ecs_output=$(aws ecs create-service \
		--cluster $deploy_cluster_id \
		--service-name $deploy_service_name \
		--task-definition $release_arn \
		--launch-type FARGATE \
		--network-configuration "awsvpcConfiguration={subnets=[$ECS_SERVICE_SUBNETS],securityGroups=[$deploy_service_security_group_id]}" \
		--desired-count $deploy_desired_count \
		--enable-execute-command \
		--deployment-configuration "maximumPercent=200,minimumHealthyPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}" \
		--propagate-tags TASK_DEFINITION \
		--tags $deploy_json_workload_resource_tags \
        $( [ "$deploy_process_type" = "web" ] && echo "--load-balancers targetGroupArn=$provision_target_group_arn,containerName=$deploy_repository_slug,containerPort=$PORT")
		)
		echo "----> First deployment of $release_arn with $deploy_desired_count task(s) in progress on ECS..."
	else
		deploy_ecs_output=$(aws ecs update-service \
		--cluster $deploy_cluster_id \
		--service $deploy_service_name \
		--task-definition $release_arn \
		--network-configuration "awsvpcConfiguration={subnets=[$ECS_SERVICE_SUBNETS],securityGroups=[$deploy_service_security_group_id]}" \
		--enable-execute-command \
		--deployment-configuration "maximumPercent=200,minimumHealthyPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}" \
		--propagate-tags TASK_DEFINITION \
		--force-new-deployment \
		$( [ -z "$deploy_max_autoscaling_count" ] && echo "--desired-count $deploy_desired_count")
		)
		echo "----> Rolling deployment of $release_arn with $deploy_desired_count task(s) in progress on ECS..."
	fi

	if [[ ! -z "$NEW_RELIC_API_KEY" && ! -z "$NEW_RELIC_APP_ID" ]]; then
		echo "----> Registering deployment with NewRelic APM"
		deploy_newrelic_response=$(curl \
			 -s \
			 -o /dev/null \
		     -X POST "https://api.newrelic.com/v2/applications/$NEW_RELIC_APP_ID/deployments.json" \
			 -H "Api-Key:$NEW_RELIC_API_KEY" \
			 -w "%{http_code}" \
			 -H "Content-Type: application/json" \
			 -d \
			"{
				\"deployment\": {
					\"revision\": \"${release_arn#*/}\"
				}
			}"
		)

		if test $deploy_newrelic_response -ne 201; then
			echo "    WARNING: NewRelic deployment registration failed!"
		fi
	fi

	if [ ! -z "$deploy_max_autoscaling_count" ]; then
		echo "----> Registering scalable target for $deploy_process_type"
		aws application-autoscaling register-scalable-target \
		--service-namespace ecs \
		--resource-id service/$deploy_cluster_id/$deploy_service_name \
		--scalable-dimension ecs:service:DesiredCount \
		--min-capacity $deploy_desired_count \
		--max-capacity $deploy_max_autoscaling_count

		for policy in ${deploy_autoscaling_policies//;/ }; do
			deploy_target_value=${policy#*=}
			case $policy in
				cpu=*)
					deploy_predefined_metric_type="ECSServiceAverageCPUUtilization"
					type_of='cpu'
					;;
				mem=*)
					deploy_predefined_metric_type="ECSServiceAverageMemoryUtilization"
					type_of='mem'
					;;
				alb=*)
					deploy_predefined_metric_type="ALBRequestCountPerTarget"
					type_of='alb'
					deploy_loadbalancer_arn=$(aws elbv2 describe-load-balancers --name $deploy_cluster_id --query 'LoadBalancers[0].LoadBalancerArn' --output text)
					deploy_targetgroup_arn=$(aws elbv2 describe-target-groups --load-balancer-arn $deploy_loadbalancer_arn --query 'TargetGroups[0].TargetGroupArn' --output text)
					if [[ $deploy_loadbalancer_arn =~ app.* ]]; then
  					deploy_loadbalancer_arn_final_portion=${BASH_REMATCH[0]}
					fi
					if [[ $deploy_targetgroup_arn =~ targetgroup.* ]]; then
  					deploy_targetgroup_arn_final_portion=${BASH_REMATCH[0]}
					fi
					deploy_resource_label=$deploy_loadbalancer_arn_final_portion/$deploy_targetgroup_arn_final_portion
					;;
				*)
					echo "Error: Unknown autoscaling policy $policy. Valid policies are: cpu=<value>, mem=<value>, alb=<value>"
					exit 1
					;;
			esac
			if [[ $type_of == 'alb' ]]; then
				deploy_predefined_metric_specification="{PredefinedMetricType=$deploy_predefined_metric_type,ResourceLabel=$deploy_resource_label}"
			else
				deploy_predefined_metric_specification="{PredefinedMetricType=$deploy_predefined_metric_type}"
			fi
			deploy_current_scaling_policy=$(aws application-autoscaling describe-scaling-policies --service-namespace ecs --policy-names $deploy_service_name-$type_of-scaling-policy --query 'ScalingPolicies[0].TargetTrackingScalingPolicyConfiguration')
			deploy_current_scale_out_cooldown=$(echo $deploy_current_scaling_policy | jq --raw-output '.ScaleOutCooldown // 300')
			deploy_current_scale_in_cooldown=$(echo $deploy_current_scaling_policy | jq --raw-output '.ScaleInCooldown // 300')
			echo "----> Registering scaling policies for $deploy_process_type with $deploy_predefined_metric_type=$deploy_target_value"
			deploy_put_scaling_policy_return=$(aws application-autoscaling put-scaling-policy \
			--service-namespace ecs \
			--policy-name $deploy_service_name-$type_of-scaling-policy \
			--resource-id service/$deploy_cluster_id/$deploy_service_name \
			--scalable-dimension ecs:service:DesiredCount \
			--policy-type TargetTrackingScaling \
			--target-tracking-scaling-policy-configuration "TargetValue=$deploy_target_value,PredefinedMetricSpecification=$deploy_predefined_metric_specification,ScaleOutCooldown=$deploy_current_scale_out_cooldown,ScaleInCooldown=$deploy_current_scale_in_cooldown")
		done
	#else
	 	# TODO: remove scalable target if it exists
		#echo "----> Deregistering unnecessary scalable target for $deploy_process_type"
		#aws application-autoscaling deregister-scalable-target \
		#--service-namespace ecs \
		#--scalable-dimension ecs:service:DesiredCount \
		#--resource-id service/$deploy_cluster_id/$deploy_service_name
	fi
fi

if [ "$deploy_process_type" = "scheduledtasks" ]; then
	echo "----> Deploying scheduled tasks as EventBridge rules"
	deploy_scheduled_tasks_path=$(grep scheduledtasks Procfile | cut -d':' -f2 | xargs)
	if [ -f "$deploy_scheduled_tasks_path" ]; then
        deploy_alb_subnets=$(jq --raw-input --raw-output 'split(",")' <<<"$ECS_SERVICE_SUBNETS")
        deploy_alb_security_groups=$(jq --raw-input --raw-output 'split(",")' <<<"$deploy_service_security_group_id")
		while IFS= read -r line; do
			deploy_scheduled_task_name=$(echo $line | cut -d' ' -f1)
			aws events put-rule \
			--name $deploy_scheduled_task_name \
			--schedule "$(echo $line | cut -d' ' -f2- | cut -d')' -f1))"

			deploy_command_override=$(echo $line | cut -d')' -f2 | xargs)
			echo "----> Defining scheduled task $deploy_scheduled_task_name with command $deploy_command_override"
			aws events put-targets \
			--rule $deploy_scheduled_task_name \
			--targets "[
				{
					\"Id\": \"$deploy_scheduled_task_name\",
					\"Arn\": \"arn:aws:ecs:$AWS_REGION:$deploy_account_id:cluster/$deploy_cluster_id\",
					\"RoleArn\": \"arn:aws:iam::$deploy_account_id:role/ecsEventsRole\",
					\"Input\": \"{ \\\"containerOverrides\\\": [ { \\\"name\\\": \\\"$deploy_repository_slug\\\", \\\"command\\\": [ \\\"$deploy_command_override\\\" ] } ] }\",
					\"EcsParameters\": {
						\"TaskCount\": 1,
						\"TaskDefinitionArn\": \"$release_arn\",
						\"LaunchType\": \"FARGATE\",
						\"NetworkConfiguration\": {
							\"awsvpcConfiguration\": {
								\"Subnets\": $deploy_alb_subnets,
								\"SecurityGroups\": $deploy_alb_security_groups,
								\"AssignPublicIp\": \"DISABLED\"
							}
						}
					}
				}
			]"
		done < $deploy_scheduled_tasks_path
	fi
fi