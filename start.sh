#!/usr/bin/env bash
set -eo pipefail

############################################
# Global variables
############################################
remote_dir="upload"
logs_dir="logs"
pem_file="ec2.pem"
client_list_file="client.list"
server_list_file="server.list"
single_server_list_file="single-server.list"
ssh_user="ubuntu"
# We don't want host key confirmation and to clutter the known hosts file with temporary EC2 instances
ssh_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
base_port=12000
is_ec2=""
terraform_output=""

jar_hint="JAR path arguments should be relative to the current directory (e.g. $remote_dir/server.jar)"
quoted_hint="Arguments wrapped in double quotes need to be quoted to allow for multiple arguments to be passed (e.g. \"--arg1 value1 --arg2 value2\"). If you have nothing to pass, use \"\"."
option_hint="Arguments wrapped in square brackets (i.e. [<arg>]) are optional"

############################################
# Helper functions
############################################

# Display usage information
usage() {
  echo "Usage: $0 <command>"
}

# Display command information
command_info() {
  usage
  echo "Commands:"
  echo "  Run within EC2:"
  echo "    setup: Install required packages and create directories"
  echo "    netem-enable: Enable network emulation"
  echo "    netem-disable: Disable network emulation"
  echo "  Run from local machine:"
  echo "    upload: Upload files inside $remote_dir/ to all remote instances"
  echo "    server: Run the server locally or on the remote instance"
  echo "    kill-server: Kill the server(s) running locally or on the remote instance"
  echo "    client: Run the client locally, or on the remote instance with an accompanying single server"
  echo "    fetch-logs: Fetch JAR logs from all remote instances and save them in $logs_dir/"
  echo "  General:"
  echo "    help: Display usage information"
  echo "Notes:"
  echo "  - The local commands are listed in the order they should be run"
  echo "  - $jar_hint"
  echo "  - $quoted_hint"
  echo "  - $option_hint"
}

# Check if the script is running inside an EC2 instance
check_ec2() {
  if [ -n "$is_ec2" ]; then
    echo "$is_ec2"
    return
  fi

  # Source: https://serverfault.com/questions/462903

  # Check if the DMI decode command is available
  if [ -x "$(command -v dmidecode)" ]; then
    # Check if the DMI data is available
    if sudo dmidecode -s system-uuid &>/dev/null; then
      # Check if the DMI data contains EC2 string
      if sudo dmidecode -s system-uuid | grep -q '^[Ee][Cc]2'; then
        is_ec2=yes
      else
        is_ec2=no
      fi
    else
      is_ec2=no
    fi

  # Simple check will work for many older instance types
  elif [ -f /sys/hypervisor/uuid ]; then
    # File should be readable by non-root users.
    if [ $(head -c 3 /sys/hypervisor/uuid) == "ec2" ]; then
      is_ec2=yes
    else
      is_ec2=no
    fi

  # This check will work on newer m5/c5 instances, but only if you have root
  elif [ -r /sys/devices/virtual/dmi/id/product_uuid ]; then
    # If the file exists AND is readable by us, we can rely on it.
    if [ $(head -c 3 /sys/devices/virtual/dmi/id/product_uuid) == "EC2" ]; then
      is_ec2=yes
    else
      is_ec2=no
    fi

  else
    # Fallback check of http://169.254.169.254/
    if $(curl -s -m 5 http://169.254.169.254/latest/dynamic/instance-identity/document | grep -q availabilityZone); then
      is_ec2=yes
    else
      is_ec2=no
    fi

  fi

  echo "$is_ec2"
}

# Error out if the script is not running on the expected host
expect_ec2() {
  ec2_expected=$1
  ec2=$(check_ec2)
  if [ "$ec2" != "$ec2_expected" ]; then
    if [ "$ec2_expected" == "yes" ]; then
      echo "Error: This command only runs on EC2 instances"
    else
      echo "Error: This command only runs locally, not on EC2 instances"
    fi
    exit 1
  fi
}

# Get and cache the terraform output
get_terraform_output() {
  if [ -z "$terraform_output" ]; then
    terraform_output=$(terraform output -json instance_details)
  fi
  echo "$terraform_output"
}

# Upload files to the remote server
upload_files() {
  details=$(get_terraform_output)
  for public_dns in $(echo "${details}" | jq -r '.[].public_dns'); do
    echo "Copying files to $public_dns"
    scp -i $pem_file $ssh_options $1 $ssh_user@$public_dns:/tmp/$2
  done
}

# Generate the server list
generate_server_lists() {
  number_of_servers=$1
  target=$2

  public_ip="127.0.0.1"
  private_ip="127.0.0.1"

  if [ "$target" == "remote" ]; then
    details=$(get_terraform_output)
    public_ip=$(echo "${details}" | jq -r '.[0].public_ip')
    private_ip=$(echo "${details}" | jq -r '.[0].private_ip')
  fi

  # (Re)create the server and client lists
  echo "${public_ip}:${base_port}" >$remote_dir/$client_list_file
  echo "${private_ip}:${base_port}" >$remote_dir/$server_list_file

  for ((i = 1; i < number_of_servers; i++)); do
    echo "${public_ip}:$((base_port + i))" >>$remote_dir/$client_list_file
    echo "${private_ip}:$((base_port + i))" >>$remote_dir/$server_list_file
  done

  echo "127.0.0.1:43100" >$remote_dir/$single_server_list_file

  if [ "$target" == "remote" ]; then
    upload_files "$remote_dir/$server_list_file $remote_dir/$single_server_list_file $remote_dir/$client_list_file" "$remote_dir/"
  fi
}

# Run the server script
run_server_script() {
  target=$1
  jar_file=$2 # Passing "" will kill running servers and not start new ones
  jar_args=$3

  if [ "$target" == "local" ]; then
    chmod +x server.sh
    ./server.sh "$jar_file" "$jar_args" $remote_dir/$server_list_file $logs_dir
  else
    details=$(get_terraform_output)
    public_dns=$(echo "${details}" | jq -r '.[0].public_dns')
    ssh -i $pem_file $ssh_options $ssh_user@$public_dns \
      <<ENDSSH
cd /tmp
mkdir -p "$logs_dir"
chmod +x /tmp/server.sh
/tmp/server.sh "$jar_file" "$jar_args" $remote_dir/$server_list_file $logs_dir
ENDSSH
  fi
}

############################################
# Command functions
############################################

# Handle setup on EC2 instances
cmd_setup_remote() {
  expect_ec2 yes
  mkdir -p $remote_dir $logs_dir
  sudo apt-get update
  sudo apt-get install openjdk-21-jdk-headless iproute2 jq -y
}

# Enable network emulation
cmd_netem_enable() {
  expect_ec2 yes
  interfaces=$(ip -json a | jq -r '.[].ifname')
  for iface in $interfaces; do
    sudo tc qdisc replace dev $iface root netem delay 5msec loss 2.5%
  done
}

# Disable network emulation
cmd_netem_disable() {
  expect_ec2 yes
  interfaces=$(ip -json a | jq -r '.[].ifname')
  for iface in $interfaces; do
    sudo tc qdisc del dev $iface root
  done
}

# Upload files locally to EC2 instances
cmd_upload_files() {
  expect_ec2 no
  upload_files "-r $remote_dir/" ""
}

# Run the server
cmd_run_server() {
  re='^(remote|local)$'
  re2='^[0-9]+$'
  if [[ "$#" -ne 5 || ! "$2" =~ $re || ! "$3" =~ $re2 ]]; then
    echo "Usage: $0 server <local/remote> <number of servers> <jar path> \"<jar args>\""
    echo "Notes:"
    echo "  - $jar_hint"
    echo "  - $quoted_hint"
    exit 1
  fi
  target=$2
  num_servers=$3
  jar_file=$4
  jar_args=$5
  generate_server_lists $num_servers $target

  run_server_script $target $jar_file "$jar_args"
}

cmd_kill_server() {
  re='^(remote|local)$'
  if [[ "$#" -ne 2 || ! "$2" =~ $re ]]; then
    echo "Usage: $0 kill-server <local/remote>"
    exit 1
  fi

  if [ ! -f "$remote_dir/$server_list_file" ]; then
    echo "Error: List of servers to kill ($remote_dir/$server_list_file) not found"
    exit 1
  fi

  run_server_script $2 "" ""
}

# Run the client
cmd_run_client() {
  re='^(remote|local)$'
  text=$(
    cat <<EOM
Usage: $0 client <local/remote> <client jar path> "<jar args>" [<server jar path> "<jar args>"]
Notes:
  - Make sure the server command has been run first
  - The optional server details are only permitted on remote runs
  - $jar_hint
  - $quoted_hint
EOM
  )

  if [[ ! "$2" =~ $re ]]; then
    echo -e "$text"
    exit 1
  fi
  target=$2

  # Make sure the server command has been run first so that the .list files are available
  if [ ! -f "$remote_dir/$server_list_file" ]; then
    echo "Error: The server command must be run first"
    exit 1
  fi

  if [[ $target == "local" ]]; then
    if [[ "$#" -ne 4 ]]; then
      echo -e "$text"
      exit 1
    fi
    echo "Running the client..."
    cd $logs_dir && java -jar ../$3 --servers-list ../$remote_dir/$client_list_file $4
    echo "Client run completed, please view the generated logs"
  else
    if [[ "$#" -ne 4 && "$#" -ne 6 ]]; then
      echo -e "$text"
      exit 1
    fi

    server_echo="echo \"Skipping starting single server\""
    server_java=""
    if [[ "$#" -eq 6 ]]; then
      server_echo="echo \"Starting server\""
      server_java="java -Xmx64m -jar $5 --servers-list $remote_dir/$server_list_file $6 > $logs_dir/server.log 2>&1 &"
    fi

    details=$(get_terraform_output)
    public_dns=$(echo "${details}" | jq -r '.[1].public_dns')
    ssh -i $pem_file $ssh_options $ssh_user@$public_dns \
      <<ENDSSH
cd /tmp
mkdir -p $logs_dir
$server_echo
$server_java
echo "Running the client..."
cd $logs_dir && java -jar ../$3 --servers-list ../$remote_dir/$client_list_file $4
ENDSSH
    echo "Client run completed, fetching the logs..."
    cmd_fetch_logs
  fi
}

# Fetch logs from the remote server
cmd_fetch_logs() {
  expect_ec2 no
  details=$(get_terraform_output)
  for public_dns in $(echo "${details}" | jq -r '.[].public_dns'); do
    echo "Fetching logs from $public_dns"
    scp -i $pem_file $ssh_options -r $ssh_user@"$public_dns:/tmp/$logs_dir" "."
  done
}

############################################
# Main script execution
############################################
command=$1
if [ -z "$command" ]; then
  command_info
  exit 0
fi

# Ensure the script is run from the correct directory
# Ref: https://stackoverflow.com/questions/3349105
cd "$(dirname "$0")"

case $command in
setup)
  cmd_setup_remote
  ;;
netem-enable)
  cmd_netem_enable
  ;;
netem-disable)
  cmd_netem_disable
  ;;
upload)
  cmd_upload_files
  ;;
server)
  cmd_run_server "$@"
  ;;
kill-server)
  cmd_kill_server "$@"
  ;;
client)
  cmd_run_client "$@"
  ;;
fetch-logs)
  cmd_fetch_logs
  ;;
help | --help)
  command_info
  ;;
*)
  echo "Invalid command"
  command_info
  exit 1
  ;;
esac
