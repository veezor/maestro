#!/bin/bash

set -eox pipefail

if [ ! -z "$MAESTRO_BRANCH_OVERRIDE" ]; then
    BRANCH=$MAESTRO_BRANCH_OVERRIDE
else
    BRANCH=$CODEBUILD_SOURCE_VERSION
fi

echo "AWS CLI Version: $(aws --version)"
echo "Buildpack CLI Version: $(pack --version)"

AWS_ACCOUNT_ID=$(cut -d':' -f5 <<<$CODEBUILD_BUILD_ARN)
REPO_SLUG=${CODEBUILD_SOURCE_REPO_URL#*://*/}
REPO_SLUG=${REPO_SLUG%.git}
REPO_SLUG=${REPO_SLUG/\//-}
COMMIT_SHORT=$(head -c 8 <<<$CODEBUILD_RESOLVED_SOURCE_VERSION)
APP_SECRETS=$(aws secretsmanager get-secret-value --secret-id $BRANCH/$REPO_SLUG)
IMAGE_NAME=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_SLUG-$BRANCH:$COMMIT_SHORT

build.sh --image-name $IMAGE_NAME \
--application-secrets "$APP_SECRETS"

if [ -z "$ECS_CLUSTER_ID" ]; then
  export ECS_CLUSTER_ID=$REPO_SLUG-$BRANCH
fi

main_processes=$(pack inspect $IMAGE_NAME | sed '0,/^Processes:$/d' | tail -n +2 | cut -d' ' -f3)
main_processes=${main_processes%$'\n'*}
main_processes=${main_processes%$'\n'}
main_services=$(aws ecs list-services --cluster $ECS_CLUSTER_ID)
while IFS= read -r line; do
    main_create_service=$(jq ".serviceArns[] | select(endswith(\"$REPO_SLUG-$BRANCH-$line\"))" <<<$main_services)
    release.sh --image-name $IMAGE_NAME \
    --process-type $line \
    --repository-slug $REPO_SLUG \
    --branch-name $BRANCH \
    --cluster-id $ECS_CLUSTER_ID \
    
    provision.sh --process-type $line \
    --repository-slug $REPO_SLUG \
    --branch-name $BRANCH

    deploy.sh --process-type $line \
    --service-name $REPO_SLUG-$BRANCH-$line \
    --cluster-id $ECS_CLUSTER_ID \
    --repository-slug $REPO_SLUG \
    $( [ -z "$main_create_service" ] && echo "--create-service")
done <<< "$main_processes"