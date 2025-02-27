#!/bin/bash
render_task_definition=./templates/task-definition.json
render_container_name=placeholder
render_process_type=web

echo $render_task_definition
echo $render_container_name
echo $render_process_type

cat <<< $(jq ".containerDefinitions[]=(.containerDefinitions[] | select(.name==\"$render_container_name\") | .entryPoint[0] = \"$render_process_type\" | .portMappings[0] | .name = \"$render_container_name-$render_process_type\")" $render_task_definition) > output.json
cat output.json