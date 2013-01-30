.SILENT: state stop acl-all acl-get acl-set acl-del account-all account-get account-set account-del

###############################################################################
## Make parameters
###############################################################################
mqtt_port=1883
mqtts_port=undefined
node=fubar
master=undefined
cookie=sharedsecretamongnodes
# ssh_host=localhost
# ssh_port=22

## Static values
APP=fubar
export RUN_ERL_LOG_GENERATIONS:=10
export RUN_ERL_LOG_MAXSIZE:=1024000

# Compile source codes only.
compile:
	./rebar compile

# Start the program in test mode.
test: compile
	mkdir -p priv/data
	mkdir -p priv/log/$(node)
	erl -pa ebin deps/*/ebin +A 100 +K true +P 10000000 +W w -boot start_sasl \
		-sname $(node) -setcookie $(cookie) -s reloader -s $(APP) \
		-mnesia dir '"priv/data/$(node)"' \
		-env MQTT_PORT $(mqtt_port) -env MQTTS_PORT $(mqtts_port) -env FUBAR_MASTER $(master)

# Start the program in production mode.
run: compile
	mkdir -p priv/data
	mkdir -p priv/log/$(node)
	mkdir -p /tmp/$(node)
	run_erl -daemon /tmp/$(node)/ $(CURDIR)/priv/log/$(node) \
		"erl -pa $(CURDIR)/ebin $(CURDIR)/deps/*/ebin +A 100 +K true +P 10000000 +W w -boot start_sasl \
			-sname $(node) -setcookie $(cookie) -s $(APP) \
			-mnesia dir '\"$(CURDIR)/priv/data/$(node)\"' \
			-env MQTT_PORT $(mqtt_port) -env MQTTS_PORT $(mqtts_port) -env FUBAR_MASTER $(master)"

stop:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` stop

state:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` state

acl-all:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` acl all

ip=127.0.0.1
allow=true

acl-get:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` acl get $(ip)

acl-set:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` acl set $(ip) $(allow)

acl-del:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` acl del $(ip)

account-all:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` account all

username=undefined
password=undefined

account-get:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` account get $(username)

account-set:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` account set $(username) $(password)

account-del:
	erl -pa ebin deps/*/ebin -noinput -hide -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` account del $(username)

# Debug running program in production mode.
debug:
#	ssh $(ssh_host) -p $(ssh_port) -tt /usr/local/bin/to_erl /tmp/$(node)/
	to_erl /tmp/$(node)/

# Launch a shell for client.
client: compile
	erl -pa ebin deps/*/ebin +A 16 +K true +P 1000000 +W w -s reloader

# Make a textual SASL log snapshot.
dump:
	priv/script/dump-log.escript $(node)

# Perform unit tests.
check: compile
	./rebar eunit

# Clear all the binaries and dependencies.  The runtime remains intact.
clean: delete-deps
	rm -rf *.dump
	./rebar clean

# Clear the runtime.
reset:
	rm -rf priv/data/$(node)

# Generate documents.
doc:
	./rebar doc

deps: get-deps
	./rebar update-deps

get-deps:
	./rebar get-deps

delete-deps:
	./rebar delete-deps
