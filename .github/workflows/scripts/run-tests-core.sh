#!/usr/bin/env bash

set -eu
set -o pipefail


source "${BASH_SOURCE[0]%/*}"/lib/testing.sh


cid_es="$(container_id elasticsearch)"
cid_ls="$(container_id logstash)"
cid_kb="$(container_id kibana)"

ip_es="$(service_ip elasticsearch)"
ip_ls="$(service_ip logstash)"
ip_kb="$(service_ip kibana)"

grouplog 'Wait for readiness of Elasticsearch'
poll_ready "$cid_es" 'http://elasticsearch:9200/' --resolve "elasticsearch:9200:${ip_es}" -u 'elastic:testpasswd'
endgroup

grouplog 'Wait for readiness of Logstash'
poll_ready "$cid_ls" 'http://logstash:9600/_node/pipelines/main?pretty' --resolve "logstash:9600:${ip_ls}"
endgroup

grouplog 'Wait for readiness of Kibana'
poll_ready "$cid_kb" 'http://kibana:5601/api/status' --resolve "kibana:5601:${ip_kb}" -u 'kibana_system:testpasswd'
endgroup

log 'Sending message to Logstash TCP input'

declare -i was_retried=0

# retry for max 10s (5*2s)
for _ in $(seq 1 5); do
	if echo 'dockerelk' | nc -q0 "$ip_ls" 50001; then
		break
	fi

	was_retried=1
	echo -n 'x' >&2
	sleep 2
done
if ((was_retried)); then
	# flush stderr, important in non-interactive environments (CI)
	echo >&2
fi

declare -a refresh_args=( '-X' 'POST' '-s' '-w' '%{http_code}' '-u' 'elastic:testpasswd'
	'http://elasticsearch:9200/logs-generic-default/_refresh'
	'--resolve' "elasticsearch:9200:${ip_es}"
)

echo "curl arguments: ${refresh_args[*]}"

# It might take a few seconds before the indices and alias are created, so we
# need to be resilient here.
was_retried=0

# retry for max 10s (10*1s)
for _ in $(seq 1 10); do
	output="$(curl "${refresh_args[@]}")"
	if [ "${output: -3}" -eq 200 ]; then
		break
	fi

	was_retried=1
	echo -n 'x' >&2
	sleep 1
done
if ((was_retried)); then
	# flush stderr, important in non-interactive environments (CI)
	echo >&2
fi

log 'Searching message in Elasticsearch'

query=$( (IFS= read -r -d '' data || echo "$data" | jq -c) <<EOD
{
  "query": {
    "term": {
      "message": "dockerelk"
    }
  }
}
EOD
)

declare -a search_args=( '-s' '-u' 'elastic:testpasswd'
	'http://elasticsearch:9200/logs-generic-default/_search?pretty'
	'--resolve' "elasticsearch:9200:${ip_es}"
	'-H' 'Content-Type: application/json'
	'-d' "${query}"
)
declare -i count
declare response

echo "curl arguments: ${search_args[*]}"

# We don't know how much time it will take Logstash to create our document, so
# we need to be resilient here too.
was_retried=0

# retry for max 10s (10*1s)
for _ in $(seq 1 10); do
	response="$(curl "${search_args[@]}")"
	count="$(jq -rn --argjson data "${response}" '$data.hits.total.value')"
	if (( count )); then
		break
	fi

	was_retried=1
	echo -n 'x' >&2
	sleep 1
done
if ((was_retried)); then
	# flush stderr, important in non-interactive environments (CI)
	echo >&2
fi

echo "$response"
if (( count != 1 )); then
	echo "Expected 1 document, got ${count}"
	exit 1
fi
