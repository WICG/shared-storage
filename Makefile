SHELL = /bin/bash

# Automatically delete any target whose recipe fails.
.DELETE_ON_ERROR:

spec.html: spec.bs
	bikeshed --die-on=warning spec $< $@

spec-remote.html: spec.bs
	trap 'echo; cat $@; echo;' ERR;          \
	curl >$@ https://api.csswg.org/bikeshed/ \
	       --no-progress-meter               \
	       --fail-with-body                  \
	       --form die-on=warning             \
	       --form file=@$<

# These targets do not correspond to files.
.PHONY: local remote clean

local: spec.html

remote: spec-remote.html
	cp $< spec.html

clean:
	rm -f spec.html spec-remote.html
