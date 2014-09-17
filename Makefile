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
LOGDIR=log
DATADIR=priv/data

# Compile source codes only.
compile:
	@$(REBAR) compile


# Start a daemon
# Params: node (default fubar), master (in node@host format),
#         mqtt_port (default 1883), mqtts_port, http_port, cookie
run: compile
	mkdir -p $(DATADIR)
	mkdir -p $(LOGDIR)

	erl -pa apps/*/ebin deps/*/ebin +A 100 +K true +P 10000000 +W w \
		+swt low +Mummc 99999 \
		-sname fubar -setcookie cookie -config fubar \
		-mnesia dir '"priv/data/fubar"' \
		-s fubar

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
