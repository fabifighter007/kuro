#!/bin/sh

verbose=1

chirp() { [ $verbose ] && shout "$*"; return 0; }
shout() { echo "$0: $*" >&2;}
barf() { shout "$*"; exit 111; }
safe() { "$@" || barf "cannot $*"; }

chirp "Copying: Conf"
safe rm -rf ./kadena-beta/conf/*
safe cp ./conf/* ./kadena-beta/conf

chirp "Clearing out the log"
rm ./kadena-beta/log/*

chirp "Builing and Copying: OSX"
rm ./kadena-beta/bin/osx/{genconfs,kadenaserver,kadenaclient}
safe stack build --flag kadena:kill-switch
safe stack install --flag kadena:kill-switch
safe cp ./bin/genconfs ./kadena-beta/bin/osx/;
safe cp ./bin/kadenaserver ./kadena-beta/bin/osx/;
safe cp ./bin/kadenaclient ./kadena-beta/bin/osx/;

chirp "Builing and Copying: Ubuntu 16.04"
rm -rf ./kadena-beta/bin/ubuntu-16.04/{genconfs,kadenaserver,kadenaclient}
safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena-base:ubuntu-16.04 -f docker/ubuntu-base.Dockerfile .
safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena:ubuntu-16.04 -f docker/ubuntu-build.Dockerfile .
safe docker run -i -v ${PWD}:/work_dir kadena:ubuntu-16.04 << COMMANDS
cp -R /ubuntu-16.04 /work_dir/kadena-beta/bin
COMMANDS
safe cp docker/ubuntu-base.Dockerfile kadena-beta/docker/

chirp "Builing and Copying: CENTOS 6.8"
rm -rf ./kadena-beta/bin/centos-6.8/{genconfs,kadenaserver,kadenaclient}
safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena-base:centos-6.8 -f docker/centos6-base.Dockerfile .
safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena:centos-6.8 -f docker/centos6-build.Dockerfile .
safe docker run -i -v ${PWD}:/work_dir kadena:centos-6.8 << COMMANDS
cp -R /centos-6.8 /work_dir/kadena-beta/bin
COMMANDS
safe cp docker/centos6-base.Dockerfile kadena-beta/docker/

chirp "Builing and Copying: Performance Monitor"
rm -rf ./kadena-beta/static/monitor/*
safe cd ./monitor
safe npm run build
safe cd ..
safe cp -R monitor/public/* ./kadena-beta/static/monitor/

chirp "Copying Scripts"
rm ./kadena-beta/scripts/{servers.sh,create_aws_confs.sh}
safe cp ./scripts/{servers.sh,create_aws_confs.sh} ./kadena-beta/scripts

chirp "taring the result"
safe tar cvz kadena-beta/* > kadena-beta.tgz

exit 0