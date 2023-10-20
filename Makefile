SHELL=/bin/bash
BUILDREPO=https://github.com/vyos/vyos-build

# Anything in the current directory called *.chroot will be added to the
# live hooks to patch the default build
PATCHES=$(wildcard *.chroot)

ARCH=amd64
BUILDER=xrobau@gmail.com

RELEASE=1.4-$(shell date -u '+%Y-%m-%d')
BUILDDIR=vyos-build/build
RELEASEDIR=releases/$(RELEASE)
ISOFILE=vyos-$(RELEASE)-$(ARCH).iso
SRCISO=$(BUILDDIR)/$(ISOFILE)
DOCKERCMD=docker run --rm -it --privileged -v $(shell pwd)/vyos-build:/vyos -w /vyos vyos/vyos-build:current
LIVEPATCHES=$(addprefix vyos-build/data/live-build-config/hooks/live/,$(PATCHES))

help: vyos-build/.git/config
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
	@echo 'make distclean:    Deletes everything, does not ask'
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

.PHONY: docker
docker: .dockerbuild

.PHONY: redocker
redocker .dockerbuild: vyos-build/.git/config vyos-build/docker/Dockerfile
	cd vyos-build && docker build $(USECACHE) -t vyos/vyos-build:current docker
	touch .dockerbuild

.PHONY: release
ASSETS=$(ISOFILE) raw.packages build.log dpkg.dump
release: $(RELEASEDIR) $(addprefix $(RELEASEDIR)/,$(ASSETS))
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

$(RELEASEDIR):
	@mkdir -p $@

.PHONY: iso
iso $(SRCISO): .dockerbuild $(LIVEPATCHES)
	@mkdir -p $(BUILDDIR)
	$(DOCKERCMD) ./build-vyos-image --architecture $(ARCH) --build-by "$(BUILDER)" --version $(RELEASE) --build-type release --custom-package vyos-1x-smoketest iso | tee $(BUILDDIR)/build.log

vyos-build/data/live-build-config/hooks/live/%: ./%
	@echo Updating $@
	@cp $< $@

vyos-build/.git/config:
	git clone $(BUILDREPO)

.PHONY: update
update: vyos-build/.git/config
	cd vyos-build && git pull

.PHONY: clean
clean: .dockerbuild
	$(DOCKERCMD) make clean
	rm -rf $(RELEASEDIR) github

.PHONY: distclean
distclean:
	rm -rf .dockerbuild vyos-build releases github .lastbuild .buildnumber

# Debugging inside the docker-build container
.PHONY: shell
shell: .dockerbuild
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
$(GHDIR)/.release: $(GHDIR) set-ghreleasevar set-authtoken
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

