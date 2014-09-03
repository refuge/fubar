REBAR?= rebar
.SILENT: state stop acl-all acl-get acl-set acl-del account-all account-get account-set account-del 
.PHONY: rel

###############################################################################
## Make parameters
###############################################################################
node=fubar
master=undefined
mqtt_port=1883
mqtts_port=undefined
http_port=undefined
cookie=sharedsecretamongnodesofafubarcluster_youneedtochangethisforsecurity

## Static values
APP=fubar

# Compile source codes only.
compile:
	@$(REBAR) compile

LOGDIR=log
DATADIR=priv/data

# Start a daemon
# Params: node (default fubar), master (in node@host format),
#         mqtt_port (default 1883), mqtts_port, http_port, cookie
run: compile
	mkdir -p $(DATADIR)
	mkdir -p $(LOGDIR)
	erl -pa ebin deps/*/ebin +A 100 +K true +P 10000000 +W w +swt low +Mummc 99999 \
		-sname $(node) -setcookie $(cookie) -detached -config $(APP) \
		-mnesia dir '"$(DATADIR)/$(node)"' \
		-s $(APP) \
		-env MQTT_PORT $(mqtt_port) -env MQTTS_PORT $(mqtts_port) -env HTTP_PORT $(http_port) \
		-env FUBAR_MASTER $(master)

# Stop a daemon
# Params: node (default fubar), cookie
stop:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` stop

# Show a daemon state
# Params: node (default fubar), cookie
state:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` state

# Show all ACL
# Params: node (default fubar), cookie
acl-all:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` acl all

ip=127.0.0.1
allow=true

# Show an ACL
# Params: node (default fubar), ip (default 127.0.0.1), cookie
acl-get:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` acl get $(ip)

# Update an ACL
# Params: node (default fubar), ip (default 127.0.0.1), allow (default true), cookie
acl-set:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` acl set $(ip) $(allow)

# Delete an ACL
# Params: node (default fubar), ip (default 127.0.0.1), cookie
acl-del:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` acl del $(ip)

# Show all accounts
# Params: node (default fubar), cookie
account-all:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` account all

username=undefined
password=undefined

# Show an account
# Params: node (default fubar), username, cookie
account-get:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` account get $(username)

# Update an account
# Params: node (default fubar), username, password, cookie
account-set:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` account set $(username) $(password)

# Delete an account
# Params: node (default fubar), username, cookie
account-del:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` account del $(username)

client_id=undefined
on=true

# Trace on/off
trace:
	erl -pa ebin deps/*/ebin -noinput -hidden -setcookie $(cookie) -sname $(node)_control \
		-s fubar_control call $(node)@`hostname -s` trace $(client_id) $(on) 

# Connect to the shell of a daemon
# Params: node (default fubar), cookie
debug:
	erl -pa $(CURDIR)/ebin $(CURDIR)/deps/*/ebin -remsh $(node)@`hostname -s` \
	-sname $(node)_debug -setcookie $(cookie)

# Perform unit tests.
check: compile
	@$(REBAR) eunit skip_deps=true

# Perform common tests.
test: compile
	@$(REBAR) ct suites=$(APP) skip_deps=true

# Clear all the binaries and dependencies.  The data remains intact.
clean: delete-deps
	rm -rf *.dump
	rm -rf test/*.beam
	@$(REBAR) clean

# Clear all data.
reset:
	rm -rf priv/data/$(node)

# Generate documents.
doc:
	@$(REBAR) doc

# Update dependencies.
deps: get-deps
	@$(REBAR) update-deps

# Download dependencies.
get-deps:
	@$(REBAR) get-deps

# Delete dependencies.
delete-deps:
	@$(REBAR) delete-deps

rel: compile
	@$(REBAR) generate
