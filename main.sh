#!/bin/bash
set -eo pipefail

if [ $MAESTRO_DEBUG == "true" ]; then
    set -x
fi

if [ ! -z "$MAESTRO_REPO_OVERRIDE" ]; then
    REPO_SLUG=$MAESTRO_REPO_OVERRIDE
fi

if [ -z "$REPO_SLUG" ]; then
    REPO_SLUG=${CODEBUILD_SOURCE_REPO_URL#*://*/}
    REPO_SLUG=${REPO_SLUG,,}
fi
REPO_SLUG=${REPO_SLUG%.git}
REPO_SLUG=${REPO_SLUG/\//-}
REPO_SLUG=${REPO_SLUG/\./-}

if [ ! -z "$MAESTRO_BRANCH_OVERRIDE" ]; then
    BRANCH=$MAESTRO_BRANCH_OVERRIDE
else
    BRANCH=$CODEBUILD_SOURCE_VERSION
fi

if [ -z "$ECS_CLUSTER_ID" ]; then
    export ECS_CLUSTER_ID=$REPO_SLUG-$BRANCH
fi

AWS_ACCOUNT_ID=$(cut -d':' -f5 <<<$CODEBUILD_BUILD_ARN)

if [[ ! -z "$DEPLOY_WEBHOOK_URL" ]]; then
    echo "----> Registering deployment with custom deployment webhook"
    main_webhook_parsed_url=${DEPLOY_WEBHOOK_URL/\{\{CLUSTER\}\}/$ECS_CLUSTER_ID}
    main_webhook_parsed_url=${main_webhook_parsed_url/\{\{REPOSITORY\}\}/$REPO_SLUG}

    main_repo_link=$(aws codebuild batch-get-builds --ids $CODEBUILD_BUILD_ID --query 'builds[0].source.location' --output text)
    main_codebuild_link="https://$AWS_REGION.console.aws.amazon.com/codesuite/codebuild/$AWS_ACCOUNT_ID/projects/$ECS_CLUSTER_ID/history?region=$AWS_REGION"
    main_cluster_link="https://$AWS_REGION.console.aws.amazon.com/ecs/v2/clusters/$ECS_CLUSTER_ID/services?region=$AWS_REGION"

    main_webhook_parsed_url=${main_webhook_parsed_url/\{\{REPO_LINK\}\}/$main_repo_link}
    main_webhook_parsed_url=${main_webhook_parsed_url/\{\{BUILD_LINK\}\}/$main_codebuild_link}
    main_webhook_parsed_url=${main_webhook_parsed_url/\{\{CLUSTER_LINK\}\}/$main_cluster_link}

    main_webhook_response=$(curl -s -o /dev/null -w "%{http_code}" $main_webhook_parsed_url)

    if test $main_webhook_response -ne 200; then
        echo "    WARNING: Custom webhook deployment registration failed!"
    fi
fi

echo "AWS CLI Version: $(aws --version)"
echo "Buildpack CLI Version: $(pack --version)"

COMMIT_SHORT=$(head -c 8 <<<$CODEBUILD_RESOLVED_SOURCE_VERSION)
IMAGE_NAME=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_SLUG-$BRANCH:$COMMIT_SHORT

main_application_secrets=$(aws secretsmanager get-secret-value --secret-id $BRANCH/$REPO_SLUG)
main_application_environment_variables=$(jq -r '.SecretString | fromjson | to_entries | .[] | .key + "=" + (.value|tostring)' <<<$main_application_secrets)

main_export_regex="^([A-Z0-9_])+[=]+(.*)"
for ENV_LINE in $main_application_environment_variables; do
    if [[ $ENV_LINE =~ ${main_export_regex} ]]; then
        key="${ENV_LINE%%=*}"
        if [ $key == "AWS_ACCESS_KEY_ID" ] || [ $key == "AWS_SECRET_ACCESS_KEY" ]; then
            echo -e "\033[1mWARNING: Detected use of AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in environment variables. These override the IAM role provided by CodeBuild and may cause authentication issues.\033[0m"
            echo -e "\033[1mConsider renaming these variables (e.g., APP_AWS_ACCESS_KEY_ID and APP_AWS_SECRET_ACCESS_KEY) to avoid conflicts.\033[0m"
            exit 1
        fi
        export $ENV_LINE
        echo $ENV_LINE >> .env
    else
        echo "   SKIPPED: >> ${ENV_LINE}"
        main_export_errors=true
    fi
done

if [ ! -z "$main_export_errors" ]; then
    echo "    WARNING: The above noted environment variables were skipped from the export, as they were not identified as a valid value or by a flag."
fi

if [ -z "$MAESTRO_SKIP_BUILD" ]; then
    build.sh --image-name $IMAGE_NAME
    if [ ! -z "$MAESTRO_ONLY_BUILD" ]; then
        echo "----> Build completed. Skipping further steps..."
        exit 0
    fi
else
    echo "----> Skipping build and running further steps..."
fi

LATEST_IMAGE_NAME=${IMAGE_NAME | cut -d ':' -f1}
LATEST_IMAGE_NAME=$LATEST_IMAGE_NAME:latest
main_processes=$(pack inspect $LATEST_IMAGE_NAME | sed '0,/^Processes:$/d' | tail -n +2 | cut -d' ' -f3)
main_processes=${main_processes%$'\n'*}
main_processes=${main_processes%$'\n'}
# refactor line break below
main_processes="$main_processes
launcher"
while IFS= read -r line; do
    release.sh --image-name $IMAGE_NAME \
    --process-type $line \
    --repository-slug $REPO_SLUG \
    --branch-name $BRANCH \
    --cluster-id $ECS_CLUSTER_ID \
    
    provision.sh --process-type $line \
    --repository-slug $REPO_SLUG \
    --branch-name $BRANCH \
    --cluster-id $ECS_CLUSTER_ID

    if [ -z "$main_services" ]; then
        main_services=$(aws ecs list-services --cluster $ECS_CLUSTER_ID)
    fi
    
    main_create_service=$(jq ".serviceArns[] | select(endswith(\"$REPO_SLUG-$BRANCH-$line\"))" <<<$main_services)

    deploy.sh --process-type $line \
    --service-name $REPO_SLUG-$BRANCH-$line \
    --cluster-id $ECS_CLUSTER_ID \
    --repository-slug $REPO_SLUG \
    --account-id $AWS_ACCOUNT_ID \
    $( [ -z "$main_create_service" ] && echo "--create-service")
done <<< "$main_processes"