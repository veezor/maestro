#!/bin/bash

set -eo pipefail

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

if [ $(DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect $build_image_name > /dev/null ; echo $?) -eq 0 ]; then
	echo "----> Skipping build as image already exists"
else
	pack build $build_image_name \
	--env-file .env \
	--publish \
	--trust-builder \
    $( [   -z $MAESTRO_NO_CACHE ] && echo "--cache-image ${build_image_name%:*}:cache") \
    $( [ ! -z $MAESTRO_CLEAR_CACHE ] && echo "--clear-cache --env USE_YARN_CACHE=false --env NODE_MODULES_CACHE=false") \
    $( [ ! -z $MAESTRO_DEBUG ] && echo "--env NPM_CONFIG_LOGLEVEL=debug --env NODE_VERBOSE=true --verbose")
fi