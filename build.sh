#!/bin/bash

set -eo pipefail
set -x

VALID_ARGS=$(getopt -o i: --long image-name: -n 'build.sh' -- "$@")
if [[ $? -ne 0 ]]; then
	exit 1;
fi

eval set -- "$VALID_ARGS"
while [ : ]; do
	case "$1" in
		-i | --image-name)
			build_image_name=$2
			#echo "Image Name is '$2'"
			shift 2
			;;
		--) shift;
		    break
		    ;;
    esac
done

if [ -z "$build_image_name" ]; then
	echo "Error: Missing required parameter --image-name"
	exit 1
fi

if [ $(DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect $build_image_name 2> /dev/null ; echo $?) -eq 0 ]; then
	echo "----> Skipping build as image already exists"
else
	build_builder_name=`grep builder ${REPO_SUB_FOLDER:+$REPO_SUB_FOLDER/}project.toml | cut -d= -f2 | tr -d '" '`
	build_builder_tag=`echo $build_builder_name | tr /: -`
	docker pull ${build_image_name%:*}:$build_builder_tag 2> /dev/null || true
	docker tag ${build_image_name%:*}:$build_builder_tag $build_builder_name 2> /dev/null || true
    build_assume_role=$(curl -s http://169.254.170.2$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)
	echo "AWS_ACCESS_KEY_ID=$(jq -r '.AccessKeyId' <<<$build_assume_role)" >> .env
	echo "AWS_SECRET_ACCESS_KEY=$(jq -r '.SecretAccessKey' <<<$build_assume_role)" >> .env
	echo "AWS_SESSION_TOKEN=$(jq -r '.Token' <<<$build_assume_role)" >> .env
	pack build ${build_image_name%:*}:latest \
	--tag $build_image_name \
	--env-file .env \
	--publish \
	--trust-builder \
    $( [[ -n $REPO_SUB_FOLDER ]] && echo "--path ${REPO_SUB_FOLDER}") \
    $( [[ -z $MAESTRO_NO_CACHE || $MAESTRO_NO_CACHE = "false" ]] && echo "--pull-policy if-not-present --cache-image ${build_image_name%:*}:cache") \
    $( [ $MAESTRO_NO_CACHE = "true" ] && echo "--pull-policy always --clear-cache --env USE_YARN_CACHE=false --env NODE_MODULES_CACHE=false") \
    $( [ $MAESTRO_DEBUG = "true" ] && echo "--env NPM_CONFIG_LOGLEVEL=debug --env NODE_VERBOSE=true --verbose")
    docker tag $build_builder_name ${build_image_name%:*}:$build_builder_tag
	docker push ${build_image_name%:*}:$build_builder_tag 2> /dev/null
fi
