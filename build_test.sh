# make sure version is set. ie run
#    source ./set_env.sh first

./build.sh

sudo logstash -f test.logstash-output-logdna.conf --debug
