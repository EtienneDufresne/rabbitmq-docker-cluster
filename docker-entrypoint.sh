#!/bin/bash
#===============================================================================
# IMPORTANT: Do not set -eu as it breaks the clustering logic
#===============================================================================
# allow the container to be started with `--user`
if [[ "$1" == rabbitmq* ]] && [ "$(id -u)" = '0' ]; then
	if [ "$1" = 'rabbitmq-server' ]; then
		chown -R rabbitmq /var/lib/rabbitmq
	fi
	exec gosu rabbitmq "$BASH_SOURCE" "$@"
fi

# backwards compatibility for old environment variables
: "${RABBITMQ_SSL_CERTFILE:=${RABBITMQ_SSL_CERT_FILE:-}}"
: "${RABBITMQ_SSL_KEYFILE:=${RABBITMQ_SSL_KEY_FILE:-}}"
: "${RABBITMQ_SSL_CACERTFILE:=${RABBITMQ_SSL_CA_FILE:-}}"

# "management" SSL config should default to using the same certs
: "${RABBITMQ_MANAGEMENT_SSL_CACERTFILE:=$RABBITMQ_SSL_CACERTFILE}"
: "${RABBITMQ_MANAGEMENT_SSL_CERTFILE:=$RABBITMQ_SSL_CERTFILE}"
: "${RABBITMQ_MANAGEMENT_SSL_KEYFILE:=$RABBITMQ_SSL_KEYFILE}"

# https://www.rabbitmq.com/configure.html
sslConfigKeys=(
	cacertfile
	certfile
	fail_if_no_peer_cert
	keyfile
	verify
)
managementConfigKeys=(
	"${sslConfigKeys[@]/#/ssl_}"
)
rabbitConfigKeys=(
	default_pass
	default_user
	default_vhost
	hipe_compile
)
fileConfigKeys=(
	management_ssl_cacertfile
	management_ssl_certfile
	management_ssl_keyfile
	ssl_cacertfile
	ssl_certfile
	ssl_keyfile
)
allConfigKeys=(
	"${managementConfigKeys[@]/#/management_}"
	"${rabbitConfigKeys[@]}"
	"${sslConfigKeys[@]/#/ssl_}"
)

declare -A configDefaults=(
	[management_ssl_fail_if_no_peer_cert]='false'
	[management_ssl_verify]='verify_none'

	[ssl_fail_if_no_peer_cert]='true'
	[ssl_verify]='verify_peer'
)

haveConfig=
haveSslConfig=
haveManagementSslConfig=
for conf in "${allConfigKeys[@]}"; do
	var="RABBITMQ_${conf^^}"
	val="${!var:-}"
	if [ "$val" ]; then
		haveConfig=1
		case "$conf" in
			ssl_*) haveSslConfig=1 ;;
			management_ssl_*) haveManagementSslConfig=1 ;;
		esac
	fi
done
if [ "$haveSslConfig" ]; then
	missing=()
	for sslConf in cacertfile certfile keyfile; do
		var="RABBITMQ_SSL_${sslConf^^}"
		val="${!var}"
		if [ -z "$val" ]; then
			missing+=( "$var" )
		fi
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		{
			echo
			echo 'error: SSL requested, but missing required configuration'
			for miss in "${missing[@]}"; do
				echo "  - $miss"
			done
			echo
		} >&2
		exit 1
	fi
fi
missingFiles=()
for conf in "${fileConfigKeys[@]}"; do
	var="RABBITMQ_${conf^^}"
	val="${!var}"
	if [ "$val" ] && [ ! -f "$val" ]; then
		missingFiles+=( "$val ($var)" )
	fi
done
if [ "${#missingFiles[@]}" -gt 0 ]; then
	{
		echo
		echo 'error: files specified, but missing'
		for miss in "${missingFiles[@]}"; do
			echo "  - $miss"
		done
		echo
	} >&2
	exit 1
fi

# set defaults for missing values (but only after we're done with all our checking so we don't throw any of that off)
for conf in "${!configDefaults[@]}"; do
	default="${configDefaults[$conf]}"
	var="RABBITMQ_${conf^^}"
	[ -z "${!var:-}" ] || continue
	eval "export $var=\"\$default\""
done

# If long & short hostnames are not the same, use long hostnames
if [ "$(hostname)" != "$(hostname -s)" ]; then
 	: "${RABBITMQ_USE_LONGNAME:=true}"
fi

if [ "${RABBITMQ_ERLANG_COOKIE:-}" ]; then
	cookieFile='/var/lib/rabbitmq/.erlang.cookie'
	if [ -e "$cookieFile" ]; then
		if [ "$(cat "$cookieFile" 2>/dev/null)" != "$RABBITMQ_ERLANG_COOKIE" ]; then
			echo >&2
			echo >&2 "warning: $cookieFile contents do not match RABBITMQ_ERLANG_COOKIE"
			echo >&2
		fi
	else
		echo "$RABBITMQ_ERLANG_COOKIE" > "$cookieFile"
		chmod 600 "$cookieFile"
	fi
fi

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}
indent() {
	if [ "$#" -gt 0 ]; then
		echo "$@"
	else
		cat
	fi | sed 's/^/\t/g'
}
rabbit_array() {
	echo -n '['
	case "$#" in
		0) echo -n ' ' ;;
		1) echo -n " $1 " ;;
		*)
			local vals="$(join $',\n' "$@")"
			echo
			indent "$vals"
	esac
	echo -n ']'
}
rabbit_env_config() {
	local prefix="$1"; shift

	local ret=()
	local conf
	for conf; do
		local var="rabbitmq${prefix:+_$prefix}_$conf"
		var="${var^^}"

		local val="${!var:-}"

		local rawVal=
		case "$conf" in
			verify|fail_if_no_peer_cert)
				[ "$val" ] || continue
				rawVal="$val"
				;;

			hipe_compile)
				[ "$val" ] && rawVal='true' || rawVal='false'
				;;

			cacertfile|certfile|keyfile)
				[ "$val" ] || continue
				rawVal='"'"$val"'"'
				;;

			*)
				[ "$val" ] || continue
				rawVal='<<"'"$val"'">>'
				;;
		esac
		[ "$rawVal" ] || continue

		ret+=( "{ $conf, $rawVal }" )
	done

	join $'\n' "${ret[@]}"
}

if [ "$1" = 'rabbitmq-server' ] && [ "$haveConfig" ]; then
	fullConfig=()

	rabbitConfig=(
		"{ loopback_users, $(rabbit_array) }"
	)

	#=============================================================================
	THIS_NODE=$(hostname)
	CONSUL_API_URL="http://consul.service.consul:8500/v1"

	# Create a Consul session and try to aquire a lock to let the other nodes they
	# need to wait for this node to be configured
	SESSION_ID=$(curl -X PUT -d "{\"Name\": \"rabbit@$THIS_NODE\", \"TTL\": \"11s\"}" $CONSUL_API_URL/session/create | jq .ID | tr -d \")
	echo

	# If the lock can't be aquired, wait until it becomes available while
	# renewing the Consul session at every attempt
	LOCK_AQUIRED=$(curl -X PUT -d "{\"Name\": \"rabbit@$THIS_NODE\"}" $CONSUL_API_URL/kv/rabbitmq?acquire=$SESSION_ID)
	echo
	while [  "$LOCK_AQUIRED" != "true" ]; do
		sleep 5
		LOCK_AQUIRED=$(curl -X PUT -d "{\"Name\": \"rabbit@$THIS_NODE\"}" $CONSUL_API_URL/kv/rabbitmq?acquire=$SESSION_ID)
		curl -X PUT $CONSUL_API_URL/session/renew/$SESSION_ID
		echo
	done

	# Do not rerender the definitions file if on container restart
	if [ ! -f /etc/rabbitmq/rabbitmq_definitions.json ]; then
		# See https://www.rabbitmq.com/management.html
		# This creates the definitions file that contains additionnal config to set
		# when a node starts if it does not already exists:
		#   The administrator user and permission
		#   The default vhost:
		#     We only use the root vhost.
		#     Multi vhosts are use for multi tenants which we don't need.
		#   Hight Availibilty policy:
		#			Mirror's all queueus across all cluster nodes
		#     When a new node joins the cluster
		#
		# It is also possible to define queues here but for now we will let the
		# node program create the queue
		cat >> /etc/rabbitmq/rabbitmq_definitions.json <<-EOS
		{
			"users": [{
					"name": "$RABBITMQ_DEFAULT_USER",
					"password": "$RABBITMQ_DEFAULT_PASS",
					"tags": "administrator"
			}],
			"vhosts": [{
				"name": "/"
			}],
			"permissions": [{
				"user": "$RABBITMQ_DEFAULT_USER",
				"vhost": "/",
				"configure": ".*",
				"write": ".*",
				"read": ".*"
			}],
			"policies": [{
				"vhost": "/",
				"name": "mirrior_queue",
				"pattern": ".*",
				"apply-to": "queues",
				"definition": {
					"ha-mode": "all",
					"ha-sync-mode":"automatic"
				},
				"priority": 0
			}]
		}
		EOS
	fi

	# Generate the cluster configuration

	# Checks if the array constains the element. Example:
	# array=("element1" "element2" "element3")
	# containsElement "element2" "${array[@]}"
	# $? will be 1 if the array contains the element, 0 otherwise
	containsElement () {
	  local ELEMENT=
	  for ELEMENT in "${@:2}"; do
	    if [[ "$ELEMENT" == "$1" ]]; then
				return 1
	    fi
	  done
	  return 0
	}

	# Collect the healthy available node IPs using the consul dns api
	AVAILABLE_HEALTHY_NODES=()
	for i in {0..5}; do
		OTHER_NODE_IP=$(dig rabbitmq.service.consul | awk '/^;; ANSWER SECTION:$/ { getline ; print $5 ; exit }')

		if [ "$OTHER_NODE_IP" ]; then
			OTHER_NODE=$(dig -x $OTHER_NODE_IP | awk '/^;; ANSWER SECTION:$/ { getline ; print $5 }' | sed 's/\..*//')

			if [ "$ENTRYPOINT_DEBUG_LOGS" == "true" ]; then
				echo "OTHER_NODE_IP $OTHER_NODE_IP"
				echo "OTHER_NODE $OTHER_NODE"
			fi

		  containsElement "'rabbit@$OTHER_NODE'" "${AVAILABLE_HEALTHY_NODES[@]}"
		  CONTAINS_NODE=$?
		  if [ $OTHER_NODE != $THIS_NODE ] && [ $CONTAINS_NODE -eq 0 ]; then
				if [ "$ENTRYPOINT_DEBUG_LOGS" == "true" ]; then
					echo "ADDING 'rabbit@$OTHER_NODE'"
				fi
			  AVAILABLE_HEALTHY_NODES+=("'rabbit@$OTHER_NODE'")
		  fi
		fi
	done

	# Create the config entry that joins the cluster
	if [ ${#AVAILABLE_HEALTHY_NODES[@]} -gt 0 ]; then
		# Convert the array to a string that looks like: [ rabbit@node1, rabbit@node2 ]
		AVAILABLE_HEALTHY_NODES=$(echo ${AVAILABLE_HEALTHY_NODES[@]} | tr -d "\n" | jq -R -s -c 'split(" ")' | tr -d \")
		# "disc" means this is an in memory + hard drive backed cluster node
		rabbitConfig+=( "{ cluster_nodes, { $AVAILABLE_HEALTHY_NODES, disc } }" )
	fi
	#=============================================================================

	if [ "$haveSslConfig" ]; then
		IFS=$'\n'
		rabbitSslOptions=( $(rabbit_env_config 'ssl' "${sslConfigKeys[@]}") )
		unset IFS

		rabbitConfig+=(
			"{ tcp_listeners, $(rabbit_array) }"
			"{ ssl_listeners, $(rabbit_array 5671) }"
			"{ ssl_options, $(rabbit_array "${rabbitSslOptions[@]}") }"
		)
	else
		rabbitConfig+=(
			"{ tcp_listeners, $(rabbit_array 5672) }"
			"{ ssl_listeners, $(rabbit_array) }"
		)
	fi

	IFS=$'\n'
	rabbitConfig+=( $(rabbit_env_config '' "${rabbitConfigKeys[@]}") )
	unset IFS

	fullConfig+=( "{ rabbit, $(rabbit_array "${rabbitConfig[@]}") }" )

	# If management plugin is installed, then generate config consider this
	if [ "$(rabbitmq-plugins list -m -e rabbitmq_management)" ]; then
		if [ "$haveManagementSslConfig" ]; then
			IFS=$'\n'
			rabbitManagementSslOptions=( $(rabbit_env_config 'management_ssl' "${sslConfigKeys[@]}") )
			unset IFS

			rabbitManagementListenerConfig+=(
				'{ port, 15671 }'
				'{ ssl, true }'
				"{ ssl_opts, $(rabbit_array "${rabbitManagementSslOptions[@]}") }"
			)
		else
			rabbitManagementListenerConfig+=(
				'{ port, 15672 }'
				'{ ssl, false }'
			)
		fi

		fullConfig+=(
			"{ rabbitmq_management, $(rabbit_array "{ load_definitions, \"/etc/rabbitmq/rabbitmq_definitions.json\" }" "{ listener, $(rabbit_array "${rabbitManagementListenerConfig[@]}") }") }"
		)
	fi

	echo "$(rabbit_array "${fullConfig[@]}")." > /etc/rabbitmq/rabbitmq.config

	#=============================================================================
	# Do not reregister the rabbitmq service on container restart
	if [ ! -f /etc/rabbitmq/consul_service.json ]; then
		echo "Register rabbitmq as a service with a script healthcheck."

		TEST_COMMAND="curl -u ${RABBITMQ_DEFAULT_USER}:${RABBITMQ_DEFAULT_PASS} -XGET http://${THIS_NODE}:15672/api/healthchecks/node"
		CONSUL_SERVICE_FILE_PATH="/etc/rabbitmq/consul_service.json"
		THIS_NODE_IP=$(hostname -i)

		cat >> $CONSUL_SERVICE_FILE_PATH <<-EOS
		{
			"id": "rabbit@$THIS_NODE",
			"name": "rabbitmq",
			"address": "$THIS_NODE_IP",
			"port": 15672,
			"check": {
				"checkid": "rabbitmqapi",
				"name": "rabbitmq healthchecks api",
				"notes": "Calls the rabbitmq healthchecks api.",
				"interval": "15s",
				"script": "$TEST_COMMAND"
			}
		}
		EOS

		curl -s -H "Content-Type: application/json" -X POST -d @$CONSUL_SERVICE_FILE_PATH $CONSUL_API_URL/agent/service/register

		if [ "$ENTRYPOINT_DEBUG_LOGS" == "true" ]; then
			echo "CONSUL_HEALTH_CHECK_FILE $(cat $CONSUL_SERVICE_FILE_PATH)"
			echo $(curl -s $CONSUL_API_URL/agent/services | jq .)
			echo $(curl -s $CONSUL_API_URL/health/checks/rabbitmq | jq .)
			cat /etc/rabbitmq/rabbitmq.config
			cat /etc/rabbitmq/rabbitmq_definitions.json
		fi

		echo "Registered rabbitmq as a service with a script healthcheck."
	fi
	#=============================================================================
fi

combinedSsl='/tmp/combined.pem'
if [ "$haveSslConfig" ] && [[ "$1" == rabbitmq* ]] && [ ! -f "$combinedSsl" ]; then
	# Create combined cert
	cat "$RABBITMQ_SSL_CERTFILE" "$RABBITMQ_SSL_KEYFILE" > "$combinedSsl"
	chmod 0400 "$combinedSsl"
fi
if [ "$haveSslConfig" ] && [ -f "$combinedSsl" ]; then
	# More ENV vars for make clustering happiness
	# we don't handle clustering in this script, but these args should ensure
	# clustered SSL-enabled members will talk nicely
	export ERL_SSL_PATH="$(erl -eval 'io:format("~p", [code:lib_dir(ssl, ebin)]),halt().' -noshell)"
	export RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS="-pa '$ERL_SSL_PATH' -proto_dist inet_tls -ssl_dist_opt server_certfile '$combinedSsl' -ssl_dist_opt server_secure_renegotiate true client_secure_renegotiate true"
	export RABBITMQ_CTL_ERL_ARGS="$RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS"
fi

exec "$@"
