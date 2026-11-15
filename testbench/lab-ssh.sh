#!/usr/bin/env bash
# ssh into the lab VM on a given port: ./lab-ssh.sh PORT [cmd...]
p=$1; shift
exec ssh -q -i "$(dirname "$0")/lab_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$p" root@127.0.0.1 "$@"
