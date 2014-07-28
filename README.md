# Fubar #
A scalable message broker to run applications like messenger, pubsub etc.
in internet scale.  It incorporates MQTT protocol but not too strictly
in semantics.  There are also a couple of syntactic extensions on top of
the protocol and some fancy features as a server.  But basically, any
MQTT client should be able to communicate with fubar.

* Wildcard(*) subscription is not supported.
* Keep-alive negotiation extension: Fubar may respond CONNACK against
CONNECT with 2-byte keep-alive payload.  The client is recommended to use
this value as the new ping interval.
* Alternate server extension: Fubar may respond CONNACK with a new
alt-server code (6) and another server's address in the payload.  The client
is supposed to connect to the alt-server instead.
* Direct messaging: A client ID can be used in place of a topic to send
messages directly to the client rather than to a topic.
* Tracing: An administrator may monitor all the messages (with timings)
to/from specific client IDs or topics.
* [Experimental] Websocket support

---
## Getting Started ##

### Getting dependencies and building ###

	$ make deps
	$ cd deps/lager
	$ make
	$ cd ../..
	$ make

Note that lager may require independent build as it uses parse_transform.
	
### Starting a broker ###

	$ make run

There are also some command line parameters.

* `node=fubar` *default, node name*
* `mqtt_port=1883` *default, mqtt service port*
* `mqtts_port=8883` *mqtt over ssl service port*
* `http_port=80` *mqtt over websocket service port*
* `master=fubar@remote` *remote node to cluster with*
* `cookie=xxxxxx` *security cookie string*
	
You can check the broker state.

	$ make state

	== fubar@host running ==
	        name : fubar
	 description : "Scalable MQTT message broker"
	     version : "3.0.0"
	   listeners : [{mqtt,[{connections,0},{acceptors,1024}]}]
	       nodes : [fubar@host]
	      routes : 0
	      memory : [{'MB',213},
	                {load,0.03377922962411755},
	                {min_load,{fubar@host,0.03377922962411755}}]

### Playing with the broker ###

#### Preparing an account for test ####

	$ make account-set username=test password=1234

#### Getting into the broker shell ####

	$ make debug
	
#### Connecting clients ####

	1> mqtt_client_simple:connect([{client_id,<<"c1">>}, {username,<<"test">>}, {password,<<"1234">>}]).
	2> mqtt_client_simple:connect([{client_id,<<"c2">>}, {username,<<"test">>}, {password,<<"1234">>}]).

#### Subscribing and publishing messages ####

	3> mqtt_client:send(<<"c1">>, mqtt:subscribe([{topics, [<<"t1">>]}])).
	4> mqtt_client:send(<<"c2">>, mqtt:publish([{topic, <<"t1">>}, {payload, <<"hello!">>}])).

#### Direct messaging ####

This is an extra feature not originally stated in MQTT specification.
One client may use the other client's client id as a topic name to
send a message directly to the client.

	5> mqtt_client:send(<<"c2">>, mqtt:publish([{topic, <<"c1">>}, {payload, <<"world!">>}])).

#### Getting out of the broker shell ####

Press `CTRL+C` twice.
	
### Shutting down the broker gracefully ###

	make stop

---
## More Features ##

### Adding a new broker node to existing broker cluster ###

	$ make run master=name@host
	
Note) If you want to start more than one broker node in a computer,
You have to use different node name and listen port as:

	$ make run master=name@host node=other mqtt_port=1884
	
### Using account control ###

Manage account using make commands like,

	$ make account-set username=romeo password=1234
	$ make account-del username=romeo
	$ make account-all
	== fubar@host account all ==
	[<<"romeo">>,<<"juliet">>]

	$

`{auth, mqtt_account}` line can be commented out from **fubar.config** to
disable account authentication.  In this case, anyone may connect
the broker without username/password.

### Using ACL control ###

Manage access control list using make commands like,

	$ make acl-set ip=127.0.0.1 allow=true
	$ make acl-set ip=192.168.0.100 allow=false
	$ make acl-all

	== fubar@host account all ==
	[{127,0,0,1},{192,168,0,100}]

	$

If an ACL is set to `allow=true`, any client from the address may
connect the broker without username/password.  If an ACL is set to
`allow=false`, no client from the address may connect the broker even
with correct username/password.

### More parameters for a client ###

Full list of client parameters are:

	1> C3 = mqtt_client_simple:connect([
						{hostname, "localhost"},
	          {port, 1884},
	          {username, <<"romeo">>},
	          {password, <<"1234">>},
	          {client_id, <<"c1">>},
	          {keep_alive, 60},
	          clean_session,
	          {will_topic, <<"will">>},
	          {will_message, <<"bye-bye">>},
	          {will_qos, at_least_once},
	          will_retain,
	          socket_options, [...]]).

Refer `inet:setopts/2` for `socket_options` above.

### Tracing ###

Direct messages are traceable.

	$ make trace client_id=c1 on=true
	$ make trace client_id=c1 on=false

Once set, direct messages to/from the client are printed to
**log/console.log** with **TRACE** tag in **notice** level.

### Broker state is preserved ###

The broker restores all the state -- accounts, topics and subscriptions -
on restart.  To clear this state, do:

	$ make reset

### SSL support ###

#### Prepare a certificate authority ####

	$ cd priv/ssl/ca
	$ mkdir certs private
	$ chmod 700 private
	$ echo 01 > serial
	$ touch index.txt
	$ openssl req -x509 -config openssl.cnf -newkey rsa:2048 -days 365 -out cacert.pem -outform PEM -subj /CN=fubar_ca/ -nodes
	$ openssl x509 -in cacert.pem -out cacert.cer -outform DER

#### Create a server certificate ####

	$ openssl genrsa -out ../key.pem 2048
	$ openssl req -new -key ../key.pem -out ../req.pem -outform PEM -subj /CN=SomeHostName/O=YourOrganizationName/ -nodes
	$ openssl ca -config openssl.cnf -in ../req.pem -out ../cert.pem -notext -batch -extensions server_ca_extensions
	$ openssl pkcs12 -export -in ../cert.pem -out ../keycert.p12 -inkey ../key.pem -passout pass:YourPassword

Entire process is stored in batch script **priv/ssl/ca/new-certs.sh**.
So you can just,

	$ cd priv/ssl/ca
	$ ./new-certs.sh

#### Testing ####

Use `mqtts_port` command line parameter to start an SSL listener when
starting the broker.

	$ cd ../../..
	$ make test mqtts_port=8883
	(fubar@host)1>

Test basic connection with **openssl s_client**.

	$ openssl s_client -connect localhost:8883

If it succeeds, use `{transport, ranch_ssl}` option on the client side.

	$ make client
	1> ssl:start().
	2> mqtt_client_simple:connect([{port, 8883}, {transport, ranch_ssl}, {client_id, <<"ssltest">>}]).

### Load balancing ###

Fubar nodes consisting of a cluster automatically offload one another to make
loads as even as possible.  This feature incorporates an MQTT protocol extension
alternative server mechanism which is explained in the last chapter.

The load balancing behavior is controlled with several parameters in `fubar_sysmon`
module.

#### high_watermark ####

The node may use as much as **memory_limit** *(high_watermark * physical system memory)*
at most.  Once the memory consumption exceeds this boundary, the node offloads to
another node in the cluster or just drops all subsequent connections.

#### offloading_threshold ####

The node compares it's **load** *(memory usage / memory_limit)* with other nodes' load
to activate offloading.  If node A's load is higher than node B's load times
offloading_threshold T *(La > Lb * T)*, the node A offloads to the node B.

While offloading, the target can be changed when another node's load appears with
lower load.  And the node A stops offloading when La becomes greater than or
equal to the load of current offloading target Lb.

#### interval ####

`fubar_sysmon` periodically checks system memory profile.  This value controls
the check interval in milliseconds.

---
## Configurations ##

The broker configuration is stored in fubar.config.  You can edit the file
and call `fuabr:load_config/0` from the shell or call `fubar:settings/2` to
apply changes while the broker is running.

	(fubar@host)1> fubar:settings(mqtt_protocol, {max_packet_size, 8192}).

The above sample shows changing maximum MQTT packet size to 8kB.  This change
affects all the clients connection from this point on.  Note that some change
applies immediately but others require further intervention.

Refer **fubar.config** for more information.

---
## Tests ##

There are two tests ready.  One is unit test and the other is common test.

### Unit test ###

	$ make check

The above command executes unit tests included in each source module and
prints verbose results on the standard output as,

	======================== EUnit ========================
	  mqtt_protocol:928: parse_success_test_ (connect)...ok
	  mqtt_protocol:941: parse_success_test_ (connect+extra)...ok
	  mqtt_protocol:954: parse_success_test_ (connect followed by more octets)...ok
	  ...
	=======================================================
	  All 45 tests passed.
	Cover analysis: ~/.eunit/index.html

And there is a comprehensive report about the most recent test at
**~/.eunit/index.html**.

### Common test ###

	$ make test

Common test is different from unit test in that it lauches test servers to
perform black-box and white-box tests.  It is more thorough in scope of
the tests than the unit test.

All the test history is collected under **~/logs**.  Open
**~/logs/all_runs.html** to browse test reports.

---
## MQTT extensions ##

### Keep-alive negotiation ###

*TBD*

### Alternative server ###

*TBD*
