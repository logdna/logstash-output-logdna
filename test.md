
# Build
`gem build logstash-output-logdna.gemspec`
`sudo logstash-plugin install logstash-output-logdna-X.X.X.gem`

## Remove plugin
`sudo logstash-plugin remove logstash-output-logdna`


# Test

DO one of thse
* `sudo logstash -f test.logstash-output-http-logdna.conf`
* `sudo logstash -f test.logstash-output-logdna.conf`

Then enter a stirng to send the log