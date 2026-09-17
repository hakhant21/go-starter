SHELL := /bin/bash

SCRIPT := ./microservice.sh
PORT ?= 8080

ifneq ($(filter init:module,$(MAKECMDGOALS)),)
MODULE_ARG := $(word 2,$(MAKECMDGOALS))
ifneq ($(MODULE_ARG),)
.PHONY: $(MODULE_ARG)
endif
endif

ifneq ($(filter %:service,$(MAKECMDGOALS)),)
SERVICE_ARG := $(word 2,$(MAKECMDGOALS))
ifneq ($(SERVICE_ARG),)
.PHONY: $(SERVICE_ARG)
endif
endif

.DEFAULT_GOAL := help

.PHONY: help init\:module create\:service delete\:service list \
	run\:service build\:service test\:service tidy\:service clean\:service \
	build-all test-all tidy-all clean-all fmt vet check workspace doctor

help:
	@$(SCRIPT) help

init\:module:
	@if [ -z "$(MODULE_ARG)" ]; then \
		echo "Usage: make init:module github.com/owner/repo"; exit 1; \
	fi
	@$(SCRIPT) init "$(MODULE_ARG)"

create\:service:
	@if [ -z "$(SERVICE_ARG)" ]; then \
		echo "Usage: make create:service payment-service PORT=8082"; exit 1; \
	fi
	@$(SCRIPT) create "$(SERVICE_ARG)" --port "$(PORT)"

delete\:service:
	@if [ -z "$(SERVICE_ARG)" ]; then \
		echo "Usage: make delete:service payment-service"; exit 1; \
	fi
	@$(SCRIPT) delete "$(SERVICE_ARG)"

list:
	@$(SCRIPT) list

run\:service:
	@$(SCRIPT) run "$(SERVICE_ARG)"

build\:service:
	@$(SCRIPT) build "$(SERVICE_ARG)"

test\:service:
	@$(SCRIPT) test "$(SERVICE_ARG)"

tidy\:service:
	@$(SCRIPT) tidy "$(SERVICE_ARG)"

clean\:service:
	@$(SCRIPT) clean "$(SERVICE_ARG)"

build-all:
	@$(SCRIPT) each build

test-all:
	@$(SCRIPT) each test

tidy-all:
	@$(SCRIPT) each tidy

clean-all:
	@$(SCRIPT) each clean

fmt:
	@$(SCRIPT) each fmt

vet:
	@$(SCRIPT) each vet

check:
	@$(SCRIPT) check

workspace:
	@$(SCRIPT) workspace

doctor:
	@$(SCRIPT) doctor
