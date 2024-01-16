SHELL=/bin/bash
BUILDREPO=https://github.com/vyos/vyos-build

# Anything in the current directory called *.chroot will be added to the
# live hooks to patch the default build
PATCHES=$(wildcard *.chroot)

ARCH=amd64
BUILDER=xrobau@gmail.com

# Update this if needed
DEBMIRROR=--debian-mirror=http://ftp.au.debian.org/debian/

# VERSION and VERSIONNAME are updated by get-vyosversion, but are here to catch defaults
VERSION=$(shell cat .vyosversion 2>/dev/null || echo -n 'unknown')
VERSIONNAME=$(shell cat .vyosname 2>/dev/null || echo -n 'debug')
RELEASE=$(VERSION)-$(shell date -u '+%Y-%m-%d')
RELEASEDIR=releases/$(RELEASE)
ISOFILE=vyos-$(RELEASE)-$(ARCH).iso
BUILDDIR=vyos-build/build
SRCISO=$(BUILDDIR)/$(ISOFILE)
LIVEPATCHES=$(addprefix vyos-build/data/live-build-config/hooks/live/,$(PATCHES))

# If somehow jq or git live somewhere else on your machine, change these to suit
JQLOC=/usr/bin/jq
GITLOC=/usr/bin/git

help: get-vyosversion vyos-build/.git/config | $(JQLOC) $(GITLOC)
	@echo ''
	@echo '*** You are building a VyOS $(VERSIONNAME) ($(VERSION)) release. ***'
	@echo ''
	@echo 'Usage:'
	@echo ''
	@echo '  `make update` and then `make release` is usually sufficient for everything'
	@echo '  If nothing has changed in the vyos-build repo, but other packages have been'
	@echo '  updated, use `make iso` to ensure the build ISO has the latest packages, as'
	@echo '  `make release` will not be aware of them and not trigger a rebuild.'
	@echo ''
	@echo 'make update:       Updates the vyos-build repo'
	@echo 'make iso:          Builds a VyOS iso'
	@echo 'make release:      Builds everything, and puts it all in $(RELEASEDIR)'
	@echo 'make clean:        Asks the vyos-build repo to clean itself up'
	@echo 'make cleancache:   Same as make clean, but also deletes apt cache'
	@echo 'make distclean:    Deletes everything, does not ask'
	@echo ''
	@echo 'Releases:'
	@echo ''
	@echo 'make v13:          Switch to "equuleus" build branch'
	@echo 'make v14:          Switch to "sagitta" build branch'
	@echo 'make circinus:     Switch to "circinus" build branch'
	@echo 'make current:      Switch to "current" build branch (currently circinus)'
	@echo ''
	@echo 'Other tools:'
	@echo 'make iso:          Builds a VyOS iso, even if it already exists'
	@echo 'make docker:       Build the docker container only'
	@echo 'make redocker:     Forces a rebuild of the docker contaner'
	@echo 'make forcedocker:  Forces a rebuild of the docker contaner, disabling'
	@echo '                   the docker build cache.'
	@echo 'make shell:        Launches a shell in the docker build container'
	@echo 'make debug:        Launches a shell in the built chroot. Be careful to'
	@echo '                   make sure everything is correctly unmounted on exit'
	@echo 'make push:         Push the build in $(RELEASEDIR) to github, if you are xrobau'
	@echo 'make inc-ghrel:    Update/incrememnt the github release tag if needed'
	@echo ''

USECACHE=
.PHONY: forcedocker
forcedocker: USECACHE=--no-cache
forcedocker: redocker

.PHONY: get-vyosversion
get-vyosversion: .vyosversion | $(JQLOC) $(GITLOC)
	@$(eval VERSION=$(shell cat .vyosversion))
	@$(eval VERSIONNAME=$(shell cat .vyosname))

.vyosversion: .vyosname
	@jq -r .$(shell cat $<) vyos-build/data/versions >$@

.vyosname: vyos-build/data/versions
	@jq -r 'keys[0]' < $< > $@

vyos-build/data/versions: vyos-build/.git/config
.PHONY: docker
docker: .dockerbuild-$(VERSIONNAME)

DOCKERCMD=docker run --rm -it --privileged -v $(shell pwd)/vyos-build:/vyos -w /vyos vyos/vyos-build:$(VERSIONNAME)

.PHONY: redocker
redocker .dockerbuild-$(VERSIONNAME): .vyosversion vyos-build/docker/Dockerfile | get-vyosversion
	cd vyos-build && docker build $(USECACHE) -t vyos/vyos-build:$(VERSIONNAME) docker
	touch .dockerbuild-$(VERSIONNAME)

.PHONY: release
META=raw.packages build.log dpkg.dump
ASSETS=$(ISOFILE) $(META)
release: $(RELEASEDIR) $(addprefix $(RELEASEDIR)/,$(ASSETS)) | get-vyosversion
	@ls -al $(RELEASEDIR)/*

.PHONY: debug
debug: vyos-build/build/chroot
	@mount -t proc none $</proc
	@mount -t sysfs none $</sys
	@mount -t devtmpfs  none $</dev
	@mount -t devpts  none $</dev/pts
	chroot $< /bin/bash || :
	@umount $</proc $</sys $</dev/pts $</dev
	@echo "If this errors with  'not mounted', it's not a problem, as it is auto-mounted when you try to use networking"
	umount $</run/cgroup2 || :

$(RELEASEDIR)/dpkg.dump:
	@chroot $(BUILDDIR)/chroot dpkg -l > $@

$(RELEASEDIR)/$(ISOFILE): $(SRCISO)
	@cp $< $@

$(RELEASEDIR)/raw.packages: $(BUILDDIR)/live-image-$(ARCH).packages
	@cp $< $@

$(RELEASEDIR)/build.log: $(BUILDDIR)/build.log
	@cp $< $@

$(RELEASEDIR): | get-vyosversion
	@mkdir -p $@

.PHONY: iso
iso $(SRCISO): .dockerbuild-$(VERSIONNAME) $(LIVEPATCHES)
	@mkdir -p $(BUILDDIR)
	$(DOCKERCMD) ./build-vyos-image $(DEBMIRROR) --architecture $(ARCH) --build-by "$(BUILDER)" --version $(RELEASE) --build-type release --custom-package vyos-1x-smoketest iso | tee $(BUILDDIR)/build.log

vyos-build/data/live-build-config/hooks/live/%: ./%
	@echo Updating $@
	@cp $< $@

vyos-build/.git/config: | $(GITLOC)
	git clone $(BUILDREPO)

.PHONY: update
update: vyos-build/.git/config
	@rm -f $(addprefix $(GHDIR)/,$(META))
	cd vyos-build && git pull
	rm -f .vyosname .vyosversion && $(MAKE) get-vyosversion

CACHEDIR=
.PHONY: cleancache
cleancache: CACHEDIR=vyos-build/build/cache
cleancache: clean
.PHONY: clean
clean: .dockerbuild-$(VERSIONNAME)
	$(DOCKERCMD) make clean
	rm -rf $(CACHEDIR) $(RELEASEDIR) github

.PHONY: distclean
distclean:
	rm -rf .dockerbuild* .vyosname .vyosversion vyos-build releases github .lastbuild .buildnumber

# Debugging inside the docker-build container
.PHONY: shell
shell: .dockerbuild-$(VERSIONNAME)
	$(DOCKERCMD) bash

## Pushing releases to github
REPOOWNER=xrobau
REPONAME=vyos-autobuild
RELEASEDATA='{"tag_name":"$(GHRELEASE)","target_commitish":"master","name":"$(GHRELEASE)","body":"Auto-created release from $(RELEASE)","draft":false,"prerelease":false,"generate_release_notes":false}'
RELEASEURL=https://api.github.com/repos/$(REPOOWNER)/$(REPONAME)/releases
UPLOADURL=https://uploads.github.com/repos/$(REPOOWNER)/$(REPONAME)/releases/$(RELEASEID)/assets
CURLPARAMS=-L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $(AUTHTOKEN)" -H "X-GitHub-Api-Version: 2022-11-28"
GHDIR=github

.PHONY: push
push: .authtoken set-ghreleasevar set-authtoken tag-release upload-assets

.PHONY: upload-assets
upload-assets: set-ghreleasevar set-authtoken tag-release set-releaseid
	@echo Uploading $(addprefix $(GHDIR)/,$(ASSETS))
	@$(MAKE) RELEASEID=$(RELEASEID) set-authtoken $(addprefix $(GHDIR)/,$(ASSETS))

.PHONY: tag-release
tag-release: $(GHDIR)/.release

set-releaseid: set-ghreleasevar set-authtoken $(GHDIR)/.release.json
	@$(eval RELEASEID=$(shell jq -r .id $(GHDIR)/.release.json))
	@echo Found Release ID $(RELEASEID)

$(GHDIR):
	mkdir -p $(GHDIR)

.PHONY: $(GHDIR)/.release
$(GHDIR)/.release: $(GHDIR) set-ghreleasevar set-authtoken | $(GITLOC)
	@if git diff --exit-code > /dev/null; then echo 'No changes in git repo'; else echo 'There are changes, commit them'; exit 1; fi
	@if [ "$$(cat $@ 2>/dev/null)" != "$(GHRELEASE)" ]; then \
		rm -f $(GHDIR)/.release.json $(addprefix $(GHDIR)/,$(ASSETS)); \
		if [ "$$(curl -sw '%{http_code}' -o $(GHDIR)/.release.json $(CURLPARAMS) $(RELEASEURL)/tags/$(GHRELEASE))" == "404" ]; then \
			echo 'Creating $(GHRELEASE) on github'; \
			curl -s -X POST $(CURLPARAMS) $(RELEASEURL) -d $(RELEASEDATA) > $@.debug && echo $(GHRELEASE) > $@; \
		else \
			echo 'Odd, release exists in github, but not in .release'; echo $(GHRELEASE) > $@; \
		fi; \
	fi

$(GHDIR)/.release.json: $(GHDIR)/.release
	@if [ "$$(curl -sw '%{http_code}' -o $(GHDIR)/.release.json $(CURLPARAMS) $(RELEASEURL)/tags/$(GHRELEASE))" != "200" ]; then \
		echo 'Error, can not get release.json'; rm -f $@; exit 1; \
	fi

$(GHDIR)/%: $(RELEASEDIR)/%
	@echo 'Uploading $(@F) to Github...'
	@curl -X POST $(CURLPARAMS) -H "Content-Type: application/octet-stream" $(UPLOADURL)?name=$(@F) --data-binary "@$<" && ln -f $< $@


.PHONY: set-authtoken
set-authtoken: .authtoken
	$(eval AUTHTOKEN=$(shell cat .authtoken))

.authtoken:
	@echo 'Create an auth token at https://github.com/settings/tokens and then enter it here'
	@read -e -p "Please paste token: " p; [ "$$p" ] && echo $$p > .authtoken || echo 'No token provided'

# Build date for tagging builds
DATESTAMP:=$(shell date --utc +'%Y%m%d')
.lastbuild:
	@echo $(DATESTAMP) > .lastbuild

# Build number default
.buildnumber:
	@echo 1 > .buildnumber

# Set GHRELEASE (will auto-update when the day changes)
set-ghreleasevar: .lastbuild .buildnumber
	@[ "$$(cat .lastbuild)" != "$(DATESTAMP)" ] && echo $(DATESTAMP) > .lastbuild && echo 1 > .buildnumber || :
	$(eval GHRELEASE=$(shell cat .lastbuild)-$(shell cat .buildnumber))
	@echo GHRELEASE is $(GHRELEASE)

# Increment GHRELEASE
increment-ghrel: .lastbuild .buildnumber
	@[ "$$(cat .lastbuild)" != "$(DATESTAMP)" ] && echo $(DATESTAMP) > .lastbuild && echo 0 > .buildnumber || :
	@echo $$(( $$(cat .buildnumber) + 1 )) > .buildnumber

### Releases
ALLVERS=v13 v14 circinus current
.PHONY: $(ALLVERS)
GITVER-v13=equuleus
GITVER-v14=sagitta
GITVER-circinus=current
GITVER-current=current
$(ALLVERS): vyos-build/.git/config
	@BR=$(GITVER-$@); [ "$$BR" ] && (cd vyos-build && git clean -f -d; git fetch; git checkout $$BR) || (echo 'Bug asking for branch $@'; exit 1)
	@rm -f .vyosname .vyosversion; $(MAKE) get-vyosversion


### JQ and git need to exist
$(JQLOC):
	@echo "The 'jq' utility can not be found at $(JQLOC), please install it. If it is installed, update the 'JQLOC' setting in this Makefile"; exit 1
$(GITLOC):
	@echo "The 'git' tool can not be found at $(GITLOC), please install it. If it is installed, update the 'GITLOC' setting in this Makefile"; exit 1

