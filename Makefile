ESPHOME_IMAGE  := ghcr.io/esphome/esphome:2026.7.4
PODMAN         := podman run --rm --userns=keep-id -v "$(CURDIR)":/config:z -e TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||') --network=host $(ESPHOME_IMAGE)
VERSION_SCRIPT := $(CURDIR)/.esphome-version.py
VERBS          := help deploy deploy-all compile logs ping all version
DEVICES_FILE   := instances.conf

DEVICE         := $(filter-out $(VERBS),$(MAKECMDGOALS))
DEVICE_FILES   := $(wildcard devices/*.yaml)
ALL_INSTANCES  := $(shell awk 'NF && !/^#/{print $$1}' $(DEVICES_FILE))
ALL_TYPES      := $(sort $(shell awk 'NF && !/^#/{print $$2}' $(DEVICES_FILE)))

# Lookup helpers (by device name)
instance_type  = $(shell awk '$$1=="$(1)"{print $$2; exit}' $(DEVICES_FILE))
instance_ip    = $(shell awk '$$1=="$(1)"{print $$3; exit}' $(DEVICES_FILE))
# Lookup all IPs for a type
type_ips       = $(shell awk '$$2=="$(1)"{print $$3}' $(DEVICES_FILE))

assert_device  = $(if $(DEVICE),,$(error No device specified. Run 'make' to list devices))

# Resolve DEVICE to a type: instance name takes priority, else treat as type directly
resolve_type   = $(or $(call instance_type,$(1)),$(1))
# Resolve DEVICE to a list of IPs: single instance IP if instance name, else all IPs for type
resolve_ips    = $(or $(call instance_ip,$(1)),$(call type_ips,$(call resolve_type,$(1))))

define VERSION_PY
import asyncio, sys
from aioesphomeapi import APIClient

async def check(name, ip):
    client = APIClient(ip, 6053, "")
    try:
        await asyncio.wait_for(client.connect(login=False), timeout=5)
        info = await client.device_info()
        version = "{}, built {}".format(info.esphome_version, info.compilation_time)
        return name, ip, version
    except Exception as e:
        return name, ip, "ERROR: " + str(e)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass

async def main():
    args = sys.argv[1:]
    devices = list(zip(args[0::2], args[1::2]))
    results = await asyncio.gather(*(check(n, ip) for n, ip in devices))
    print("  {:<22} {:<15} {}".format("DEVICE", "IP", "VERSION"))
    print("  {:<22} {:<15} {}".format("------", "--", "-------"))
    for name, ip, version in results:
        print("  {:<22} {:<15} {}".format(name, ip, version))

asyncio.run(main())
endef

help:
	@echo "Usage: make <verb> [type|device]"
	@echo ""
	@echo "Verbs:"
	@echo "  all                 Compile all device types"
	@echo "  deploy-all          OTA flash all devices"
	@echo "  ping                Check reachability of all devices"
	@echo "  compile <type>      Compile firmware for a device type"
	@echo "  compile <device>    Compile firmware for a device's type"
	@echo "  deploy  <type>      OTA flash all devices of a type"
	@echo "  deploy  <device>    OTA flash a single device"
	@echo "  logs    <device>    Tail logs from a device"
	@echo "  logs    <type>      Tail logs (single-device types only)"
	@echo "  version             Show deployed version of all devices"
	@echo "  version <device>    Show deployed version of a device"
	@echo "  version <type>      Show deployed version of all devices of a type"
	@echo ""
	@echo "Devices:"
	@awk 'NF && !/^#/{printf "  %-22s %-25s %s\n", $$1, $$2, $$3}' $(DEVICES_FILE)

ping:
	@printf '  %-22s %-15s %s\n' DEVICE IP PING
	@printf '  %-22s %-15s %s\n' '------' '--' '----'
	@awk 'NF && !/^#/{print $$1, $$3}' $(DEVICES_FILE) | while read name ip; do \
		ping_out=$$(ping -c1 -W1 $$ip 2>/dev/null); \
		if echo "$$ping_out" | grep -q '1 received'; then \
			rtt=$$(echo "$$ping_out" | grep -oP 'time=\K[0-9.]+'); \
			ping_s="UP ($${rtt}ms)"; \
		else \
			ping_s="DOWN"; \
		fi; \
		printf '  %-22s %-15s %s\n' "$$name" "$$ip" "$$ping_s"; \
	done

deploy-all:
	@awk 'NF && !/^#/{print $$1, $$2, $$3}' $(DEVICES_FILE) | while read name type ip; do \
		if ! ping -c1 -W1 $$ip >/dev/null 2>&1; then \
			echo "=== Skipping $$name ($$ip) - unreachable ==="; \
			continue; \
		fi; \
		echo "=== Deploying $$name (devices/$$type.yaml) to $$ip ==="; \
		$(PODMAN) upload devices/$$type.yaml --device $$ip || \
			echo "WARNING: Deploy to $$name ($$ip) failed, continuing..."; \
	done

all:
	@for f in $(DEVICE_FILES); do \
		echo "=== Compiling $$f ==="; \
		$(PODMAN) compile $$f || exit 1; \
	done

compile:
	$(call assert_device)
	$(eval _TYPE := $(call resolve_type,$(DEVICE)))
	$(if $(wildcard devices/$(_TYPE).yaml),,$(error No config found for type '$(_TYPE)'))
	$(PODMAN) compile devices/$(_TYPE).yaml

deploy:
	$(call assert_device)
	$(eval _TYPE := $(call resolve_type,$(DEVICE)))
	$(eval _IPS  := $(call resolve_ips,$(DEVICE)))
	$(if $(wildcard devices/$(_TYPE).yaml),,$(error No config found for type '$(_TYPE)'))
	$(if $(_IPS),,$(error No devices found for '$(DEVICE)'))
	@for ip in $(_IPS); do \
		echo "=== Deploying devices/$(_TYPE).yaml to $$ip ==="; \
		$(PODMAN) upload devices/$(_TYPE).yaml --device $$ip || exit 1; \
	done

logs:
	$(call assert_device)
	$(eval _TYPE := $(call resolve_type,$(DEVICE)))
	$(eval _IPS  := $(call resolve_ips,$(DEVICE)))
	$(if $(wildcard devices/$(_TYPE).yaml),,$(error No config found for type '$(_TYPE)'))
	$(if $(_IPS),,$(error No instances found for '$(DEVICE)'))
	$(if $(word 2,$(_IPS)),$(error '$(_TYPE)' has multiple devices - specify device name),)
	$(PODMAN) logs devices/$(_TYPE).yaml --device $(firstword $(_IPS))

version:
	$(eval _IPS := $(call resolve_ips,$(DEVICE)))
	$(if $(DEVICE),$(if $(_IPS),,$(error No devices found for '$(DEVICE)')),)
	$(file >$(VERSION_SCRIPT),$(VERSION_PY))
	@if [ -n "$(DEVICE)" ]; then \
		args=""; \
		for ip in $(_IPS); do \
			name=$$(awk -v ip=$$ip '$$3==ip{print $$1; exit}' $(DEVICES_FILE)); \
			args="$$args $$name $$ip"; \
		done; \
	else \
		args=$$(awk 'NF && !/^#/{printf "%s %s ", $$1, $$3}' $(DEVICES_FILE)); \
	fi; \
	podman run --rm --network=host -v "$(VERSION_SCRIPT)":/tmp/version.py:z \
		--entrypoint python3 $(ESPHOME_IMAGE) /tmp/version.py $$args; \
	rc=$$?; rm -f $(VERSION_SCRIPT); exit $$rc

ALL_TARGETS := $(sort $(ALL_INSTANCES) $(ALL_TYPES))
$(ALL_TARGETS):
	@true

.DEFAULT_GOAL := help
.PHONY: $(VERBS) $(ALL_TARGETS)
