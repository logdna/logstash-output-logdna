# quick command
# sudo systemctl stop logstash; sudo sh build_scotts.sh; sudo systemctl start logstash; journalctl -f -u logstash -e

# make sure version is set. ie run
TMP=$(awk -F "version = '|'" '{print $2}' /root/logstash-output-logdna/logstash-output-logdna.gemspec)
VRS=$(echo $TMP | awk -F "logstash-output-logdna | MIT" '{print $2}')
echo "Building Logstash Output LogDNA: v$VRS"

rm /root/logstash-output-logdna/logstash-output-logdna-$VRS.gem
sudo /usr/share/logstash/bin/logstash-plugin remove logstash-output-logdna

gem build /root/logstash-output-logdna/logstash-output-logdna.gemspec

sudo /usr/share/logstash/bin/logstash-plugin install /root/logstash-output-logdna/logstash-output-logdna-$VRS.gem

#sudo systemctl start logstash

# VIEW LOGS
# journalctl -f -u logstash -e
