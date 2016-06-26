#!/bin/sh

if [ ! -d "aws-conf" ];then echo "Can't find juno/aws-conf"; exit 1; fi
cd aws-conf

cmd="$1"
case $cmd in
  config)
    for i in `cat junoservers.privateIp`; do scp -i ~/user.pem -r $i/* ec2-user@$i:; done
    exit 0
    ;;
  start)
    for i in `cat junoservers.privateIp`; do ssh -i ~/user.pem ec2-user@$i './start.sh'; done
    exit 0
    ;;
  stop)
    for i in `cat junoservers.privateIp`; do ssh -i ~/user.pem ec2-user@$i 'pkill junoserver'; done
    exit 0
    ;;
  ps)
    for i in `cat junoservers.privateIp`; do ssh -i ~/user.pem ec2-user@$i 'pgrep junoserver'; done
    exit 0
    ;;
  *)
    echo "Commands: config start stop"
    ;;
esac