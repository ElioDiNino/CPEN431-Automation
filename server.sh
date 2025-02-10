#!/usr/bin/env bash
set -eo pipefail

# NOTE: This script is only intended to be run by the start.sh script

# This is a separate script due to the need for bash loops which do not work well with the SSH here document

num_servers=$1
jar_file=$2
jar_args=$3
base_port=$4
remote_dir=$5
logs_dir=$6

for i in $(seq 0 $(($num_servers - 1))); do
  echo "Starting server $(($i + 1))"
  port=$((base_port + i))
  if [ $(lsof -i :$port | wc -l) -gt 0 ]; then
    kill -9 $(lsof -t -i:$port)
  fi
  java -Xmx64m -jar $jar_file --servers-list $remote_dir/server.list --index $i $jar_args > $logs_dir/server-$i.log 2>&1 &
done
