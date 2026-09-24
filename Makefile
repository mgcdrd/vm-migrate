.DEFAULT_GOAL := help

# Local overrides:
# ../../ansible-local.mk
-include ../../ansible-local.mk

VENV ?= .venv
PYTHON ?= python3
ANSIBLE_GALAXY ?= $(VENV)/bin/ansible-galaxy
ANSIBLE_LINT ?= $(VENV)/bin/ansible-lint

.PHONY: help venv setup install lint syntax clean

help:
	@echo "Available targets"
	@echo "  make setup       Create dev environment"
	@echo "  make install     Install Ansible dependencies"
	@echo "  make lint        Run ansible-lint"
	@echo "  make syntax      Check playbook syntax"
	@echo "  make clean       Remove generated files"

venv:
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip

setup: venv
	$(VENV)/bin/pip install \
		ansible \
		ansible-lint

install: setup
	$(ANSIBLE_GALAXY) collection install \
		-r collections/requirements.yml \
		-p collections

lint:
	$(ANSIBLE_LINT)

syntax:
	$(VENV)/bin/ansible-playbook \
		--syntax-check \
		site.yml

clean:
	rm -rf $(VENV)
