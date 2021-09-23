# quick command
# sudo systemctl stop logstash; sudo sh build_scotts.sh; sudo systemctl start logstash; journalctl -f -u logstash -e

# make sure version is set. ie run
TMP=$(awk -F "version = '|'" '{print $2}' logstash-output-logdna.gemspec)
VRS=$(echo $TMP | awk -F "logstash-output-logdna | MIT" '{print $2}')
echo "Building Logstash Output LogDNA: v$VRS"

rm logstash-output-logdna-$VRS.gem
sudo logstash-plugin remove logstash-output-logdna

gem build logstash-output-logdna.gemspec

sudo logstash-plugin install logstash-output-logdna-$VRS.gem

#sudo systemctl start logstash

# VIEW LOGS
# journalctl -f -u logstash -e
