#!/bin/bash

set -eox pipefail

VALID_ARGS=$(getopt -o a:i: --long application-secrets:,image-name: -n 'build.sh' -- "$@")
if [[ $? -ne 0 ]]; then
	exit 1;
fi

eval set -- "$VALID_ARGS"
while [ : ]; do
	case "$1" in
		-a | --application-secrets)
			build_application_secrets=$2
			#echo "Application Secrets is '$2'"
			shift 2
			;;
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

if [ -z "$build_application_secrets" ]; then
	echo "Error: Missing required parameter --application-secrets"
	exit 1
fi

if [ -z "$build_image_name" ]; then
	echo "Error: Missing required parameter --image-name"
	exit 1
fi

#jq -r '.SecretString | fromjson | to_entries | .[] | .key + "=\"" + (.value|tostring) + "\""' <<<$build_application_secrets > .env
eval $(jq -r '.SecretString | fromjson | to_entries | .[] | "export " + .key + "=\"" + (.value|tostring) + "\""' <<<$build_application_secrets)
jq -r '.SecretString | fromjson | to_entries | .[] | .key' <<<$build_application_secrets > .env

pack build $build_image_name \
--env-file .env \
--cache-image ${build_image_name%:*}:cache \
--publish