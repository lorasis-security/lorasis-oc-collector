PYTHON ?= python3
SHELLCHECK ?= .tools/shellcheck
JQ ?= .tools/jq

.PHONY: setup lint test verify
setup:
	$(PYTHON) tools/setup.py

lint:
	bash -n collect-cluster-shape.sh
	$(SHELLCHECK) collect-cluster-shape.sh
	$(PYTHON) -m py_compile tools/setup.py tests/test_collector.py tests/fake_cli.py

test:
	env -i HOME="$(HOME)" PATH="$(PATH)" COLLECTOR_TEST_JQ="$(abspath $(JQ))" $(PYTHON) -B -m unittest discover -s tests -p 'test_*.py' -v

verify: lint test
