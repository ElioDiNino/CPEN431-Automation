#!/usr/bin/env bash
set -eo pipefail

# NOTE: This script is only intended to be run by the start.sh script

# This is a separate script due to the need for bash loops which do not work well with the SSH here document

jar_file=$1
jar_args=$2
list_file=$3
logs_dir=$4

i=1

for server in $(cat $list_file); do
  port=$(echo $server | cut -d: -f2)
  if [ $(lsof -i :$port | wc -l) -gt 0 ]; then
    echo "Killing server $i"
    kill -9 $(lsof -t -i:$port)
  fi

  # Only start the server if a jar file is specified
  if [ -n "$jar_file" ]; then
    echo "Starting server $i on port $port"
    java -Xmx64m -jar $jar_file --servers-list $list_file --index $(($i - 1)) $jar_args >$logs_dir/server-$i.log 2>&1 &
  fi
  i=$((i + 1))
done
