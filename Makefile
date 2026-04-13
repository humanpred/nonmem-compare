# Makefile: Run NONMEM across Docker image variants for cross-version comparison
#
# Usage:
#   make -jN        # Run N NONMEM jobs in parallel (one docker run per CTL file)
#                   # N = number of CPU cores; use `nproc` to check available cores
#   make setup      # Copy source files into tag directories without running NONMEM
#   make clean      # Remove all generated tag directories
#
# Each result directory is named after the image tag suffix, e.g.:
#   7.6.0-ubuntu24.04-gfortran14-arm64/ode/
#   7.6.0-ubuntu24.04-gfortran14-arm64/solved/
#
# Per-run output:
#   <name>.lst       — NONMEM's own output file
#   <name>.nmfe.log  — stdout+stderr captured from the nmfe wrapper
#   .failures        — list of failed basenames (only created when runs fail)
#
# Targets are generated dynamically from:
#   - available Docker image tags (queried from local docker at parse time)
#   - CTL files found in nlmixr2test/nonmem/ode/ and nlmixr2test/nonmem/solved/
# Adding a new CTL file or pulling/building a new image is picked up automatically.

REGISTRY    := humanpredictions/nonmem
DOCKER_USER := $(shell id -u):$(shell id -g)

# Detect host architecture in Docker's naming convention (amd64, arm64, etc.)
ARCH := $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/;s/armv7l/arm/')

# Discover all locally available image tags matching this host architecture
TAGS := $(shell docker images --format "{{.Tag}}" $(REGISTRY) \
          | grep -v '<none>' | grep -- '-$(ARCH)' | sort -u)

# CTL source files live in the nlmixr2test submodule
ODE_CTL_DIR    := nlmixr2test/nonmem/ode
SOLVED_CTL_DIR := nlmixr2test/nonmem/solved

# Discover CTL files dynamically
ODE_CTLS    := $(basename $(notdir $(wildcard $(ODE_CTL_DIR)/*.ctl)))
SOLVED_CTLS := $(basename $(notdir $(wildcard $(SOLVED_CTL_DIR)/*.ctl)))

# Source files (used as prerequisites for the setup stamp)
ODE_SRCS    := $(wildcard $(ODE_CTL_DIR)/*.csv $(ODE_CTL_DIR)/*.ctl)
SOLVED_SRCS := $(wildcard $(SOLVED_CTL_DIR)/*.csv $(SOLVED_CTL_DIR)/*.ctl)

# All .lst targets — one per CTL file per image tag
ODE_LSTS    := $(foreach t,$(TAGS),$(foreach c,$(ODE_CTLS),$(t)/ode/$(c).lst))
SOLVED_LSTS := $(foreach t,$(TAGS),$(foreach c,$(SOLVED_CTLS),$(t)/solved/$(c).lst))

.PHONY: all setup clean

all: system_details.txt $(ODE_LSTS) $(SOLVED_LSTS)

# ------------------------------------------------------------------
# system_details.txt: host hardware/software snapshot for reporting
# ------------------------------------------------------------------
# Real file target — runs once; delete the file to regenerate.
# Format: INI-style [section] / key=value, parseable by R configparser,
# Python configparser, or plain grep/awk.

system_details.txt:
	@{ \
	  echo "[metadata]"; \
	  echo "generated=$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	  echo "hostname=$$(hostname -f)"; \
	  echo ""; \
	  echo "[system]"; \
	  echo "sys_vendor=$$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"; \
	  echo "product_name=$$(cat /sys/class/dmi/id/product_name 2>/dev/null)"; \
	  echo "product_version=$$(cat /sys/class/dmi/id/product_version 2>/dev/null)"; \
	  echo "product_family=$$(cat /sys/class/dmi/id/product_family 2>/dev/null)"; \
	  echo "board_vendor=$$(cat /sys/class/dmi/id/board_vendor 2>/dev/null)"; \
	  echo "board_name=$$(cat /sys/class/dmi/id/board_name 2>/dev/null)"; \
	  echo "board_version=$$(cat /sys/class/dmi/id/board_version 2>/dev/null)"; \
	  echo "chassis_type=$$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)"; \
	  echo "bios_vendor=$$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null)"; \
	  echo "bios_version=$$(cat /sys/class/dmi/id/bios_version 2>/dev/null)"; \
	  echo "bios_date=$$(cat /sys/class/dmi/id/bios_date 2>/dev/null)"; \
	  echo ""; \
	  echo "[cpu]"; \
	  echo "vendor_id=$$(grep -m1 '^vendor_id'  /proc/cpuinfo | sed 's/.*: //')"; \
	  echo "cpu_family=$$(grep -m1 '^cpu family' /proc/cpuinfo | sed 's/.*: //')"; \
	  echo "model=$$(grep -m1 '^model[[:space:]]' /proc/cpuinfo | sed 's/.*: //')"; \
	  echo "model_name=$$(grep -m1 '^model name' /proc/cpuinfo | sed 's/.*: //')"; \
	  echo "stepping=$$(grep -m1 '^stepping'    /proc/cpuinfo | sed 's/.*: //')"; \
	  echo "microcode=$$(grep -m1 '^microcode'  /proc/cpuinfo | sed 's/.*: //')"; \
	  echo "cpu_cores=$$(grep -m1 '^cpu cores'  /proc/cpuinfo | sed 's/.*: //')"; \
	  echo "threads_logical=$$(grep -m1 '^siblings'   /proc/cpuinfo | sed 's/.*: //')"; \
	  echo "threads_per_core=$$(lscpu | awk -F':[[:space:]]+' '/Thread\(s\) per core/{print $$2}')"; \
	  echo "sockets=$$(lscpu | awk -F':[[:space:]]+' '/Socket\(s\)/{print $$2}')"; \
	  echo "cpu_max_mhz=$$(lscpu | awk -F':[[:space:]]+' '/CPU max MHz/{print $$2}')"; \
	  echo "l1d_cache=$$(lscpu | awk -F':[[:space:]]+' '/L1d cache/{print $$2}')"; \
	  echo "l1i_cache=$$(lscpu | awk -F':[[:space:]]+' '/L1i cache/{print $$2}')"; \
	  echo "l2_cache=$$(lscpu | awk -F':[[:space:]]+' '/L2 cache/{print $$2}')"; \
	  echo "l3_cache=$$(lscpu | awk -F':[[:space:]]+' '/L3 cache/{print $$2}')"; \
	  echo "cpu_flags=$$(grep -m1 '^flags' /proc/cpuinfo | sed 's/.*: //')"; \
	  echo ""; \
	  echo "[os]"; \
	  . /etc/os-release && echo "os_name=$$NAME"; \
	  . /etc/os-release && echo "os_version=$$VERSION"; \
	  . /etc/os-release && echo "os_version_id=$$VERSION_ID"; \
	  . /etc/os-release && echo "os_id=$$ID"; \
	  echo "kernel=$$(uname -r)"; \
	  echo "kernel_full=$$(uname -a)"; \
	  echo "architecture=$$(uname -m)"; \
	  echo ""; \
	  echo "[memory]"; \
	  awk '/^MemTotal/    {print "mem_total_kb="     $$2}' /proc/meminfo; \
	  awk '/^MemAvailable/{print "mem_available_kb=" $$2}' /proc/meminfo; \
	} > $@
	@echo "System details written to $@"

# ------------------------------------------------------------------
# setup: create TAG/ode/ and TAG/solved/, copy source files
# ------------------------------------------------------------------
# The stem $* is the image tag (e.g. 7.6.0-ubuntu24.04-gfortran14-arm64).
# Both ode and solved subdirectories are created in a single recipe to
# avoid a race condition when many .lst targets for the same tag fire
# simultaneously and all declare this stamp as a prerequisite.

%/ode/.setup: $(ODE_SRCS) $(SOLVED_SRCS)
	mkdir -p $*/ode $*/solved
	cp $(ODE_CTL_DIR)/*.csv $(ODE_CTL_DIR)/*.ctl       $*/ode/
	cp $(SOLVED_CTL_DIR)/*.csv $(SOLVED_CTL_DIR)/*.ctl $*/solved/
	touch $@

# Convenience target: set up all directories without running NONMEM
setup: $(foreach t,$(TAGS),$(t)/ode/.setup)

# ------------------------------------------------------------------
# Per-CTL NONMEM runs: one docker container per .lst target
# ------------------------------------------------------------------
# Rules are generated dynamically for every (tag, ctl) combination.
# make -jN runs N docker containers concurrently.

define ode_lst_rule
$(1)/ode/$(2).lst: $(1)/ode/.setup
	mkdir -p "$(1)/ode/$(2)-run"
	cp "$(1)/ode/$(2).ctl" "$(1)/ode/$(2)-run/"
	ln -f $(1)/ode/*.csv "$(1)/ode/$(2)-run/" 2>/dev/null || cp -f $(1)/ode/*.csv "$(1)/ode/$(2)-run/"
	docker run --rm \
	  --user "$(DOCKER_USER)" \
	  --volume "$(CURDIR)/$(1)/ode/$(2)-run:/data" \
	  $(REGISTRY):$(1) \
	  sh -c 'cd /data && \
	    /opt/NONMEM/nm_current/util/nmfe $(2).ctl $(2).lstinterim \
	      > $(2).nmfe.log 2>&1 && \
	    grep -qF "Stop Time:" $(2).lstinterim && \
	    mv $(2).lstinterim $(2).lst \
	    || echo "FAILED: $(2)" >> .failures'
	-mv "$(1)/ode/$(2)-run/$(2).nmfe.log" "$(1)/ode/$(2).nmfe.log"
	{ [ -f "$(1)/ode/$(2)-run/.failures" ] && cat "$(1)/ode/$(2)-run/.failures" >> "$(1)/ode/.failures"; } || true
	mv "$(1)/ode/$(2)-run/$(2).lst" "$(1)/ode/$(2).lst"
endef

define solved_lst_rule
$(1)/solved/$(2).lst: $(1)/ode/.setup
	mkdir -p "$(1)/solved/$(2)-run"
	cp "$(1)/solved/$(2).ctl" "$(1)/solved/$(2)-run/"
	ln -f $(1)/solved/*.csv "$(1)/solved/$(2)-run/" 2>/dev/null || cp -f $(1)/solved/*.csv "$(1)/solved/$(2)-run/"
	docker run --rm \
	  --user "$(DOCKER_USER)" \
	  --volume "$(CURDIR)/$(1)/solved/$(2)-run:/data" \
	  $(REGISTRY):$(1) \
	  sh -c 'cd /data && \
	    /opt/NONMEM/nm_current/util/nmfe $(2).ctl $(2).lstinterim \
	      > $(2).nmfe.log 2>&1 && \
	    grep -qF "Stop Time:" $(2).lstinterim && \
	    mv $(2).lstinterim $(2).lst \
	    || echo "FAILED: $(2)" >> .failures'
	-mv "$(1)/solved/$(2)-run/$(2).nmfe.log" "$(1)/solved/$(2).nmfe.log"
	{ [ -f "$(1)/solved/$(2)-run/.failures" ] && cat "$(1)/solved/$(2)-run/.failures" >> "$(1)/solved/.failures"; } || true
	mv "$(1)/solved/$(2)-run/$(2).lst" "$(1)/solved/$(2).lst"
endef

$(foreach t,$(TAGS),\
  $(foreach c,$(ODE_CTLS),$(eval $(call ode_lst_rule,$(t),$(c))))\
  $(foreach c,$(SOLVED_CTLS),$(eval $(call solved_lst_rule,$(t),$(c)))))

# ------------------------------------------------------------------
# Clean: remove all generated tag directories
# ------------------------------------------------------------------

clean:
	@if [ -n "$(TAGS)" ]; then rm -rf $(TAGS); fi
	rm -f system_details.txt
	@echo "Cleaned result directories and system_details.txt."
