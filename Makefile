SHELL := /bin/bash

.PHONY: help \
	top1 top8 top16 top32 subsystem8 \
	perf-top16 perf-top32 perf-subsystem8 \
	fullset-subsystem fullset-subsystem-status \
	sim-all lint-sh diffcheck

SIMULATOR ?= vcs
TIMEOUT_SECS ?= 900

TOP_FIXTURE_DIR ?= datasets/mnist/lenet_real_fixture
TOP_MANIFEST_100 ?= datasets/mnist/lenet_real_manifest_100/manifest.json
TOP_SAMPLE_ROOT_100 ?= datasets/mnist/exports_full
TOP_WEIGHTS_ROOT_100 ?= datasets/mnist/lenet_real_manifest_100/weights
TOP_INPUT_MEMH_NAME ?= packed_words.memh
TOP_EXPECTED_FILE_NAME ?= label.txt
TOP_EXPECTED_FIELD ?= predicted_class

SUBSYSTEM_FIXTURE_DIR ?= datasets/mnist/lenet_fixture
SUBSYSTEM_MANIFEST ?= $(SUBSYSTEM_FIXTURE_DIR)/manifest.json
SUBSYSTEM_SAMPLE_ROOT ?= $(SUBSYSTEM_FIXTURE_DIR)
SUBSYSTEM_WEIGHTS_ROOT ?= $(SUBSYSTEM_FIXTURE_DIR)/weights

TOP_ENV = \
	SIMULATOR="$(SIMULATOR)" \
	TIMEOUT_SECS="$(TIMEOUT_SECS)" \
	FIXTURE_DIR="$(TOP_FIXTURE_DIR)" \
	MANIFEST_PATH="$(TOP_MANIFEST_100)" \
	SAMPLE_ROOT_DIR="$(TOP_SAMPLE_ROOT_100)" \
	WEIGHTS_ROOT_DIR="$(TOP_WEIGHTS_ROOT_100)" \
	INPUT_MEMH_NAME="$(TOP_INPUT_MEMH_NAME)" \
	EXPECTED_FILE_NAME="$(TOP_EXPECTED_FILE_NAME)" \
	EXPECTED_MANIFEST_FIELD="$(TOP_EXPECTED_FIELD)"

SUBSYSTEM_ENV = \
	SIMULATOR="$(SIMULATOR)" \
	TIMEOUT_SECS="$(TIMEOUT_SECS)" \
	FIXTURE_DIR="$(SUBSYSTEM_FIXTURE_DIR)" \
	MANIFEST_PATH="$(SUBSYSTEM_MANIFEST)" \
	SAMPLE_ROOT_DIR="$(SUBSYSTEM_SAMPLE_ROOT)" \
	WEIGHTS_ROOT_DIR="$(SUBSYSTEM_WEIGHTS_ROOT)"

define run_top_batch
$(TOP_ENV) COUNT="$(1)" RUN_LABEL="$(2)" RESULTS_DIR="$(3)" bash sim/run_top_lenet.sh batch
endef

define run_top_perf
$(TOP_ENV) ACCURACY_ONLY=1 COUNT="$(1)" RUN_LABEL="$(2)" RESULTS_DIR="$(3)" bash sim/run_top_lenet.sh batch
endef

define run_subsystem_batch
$(SUBSYSTEM_ENV) COUNT="$(1)" RUN_LABEL="$(2)" RESULTS_DIR="$(3)" bash sim/run_lenet_fixture.sh batch
endef

define run_subsystem_perf
$(SUBSYSTEM_ENV) ACCURACY_ONLY=1 COUNT="$(1)" RUN_LABEL="$(2)" RESULTS_DIR="$(3)" bash sim/run_lenet_fixture.sh batch
endef

help:
	@printf '%s\n' \
		'Developer entry targets:' \
		'' \
		'Correctness replay (top-level LeNet, current HB single-cluster network-level path):' \
		'  make top1      COUNT=1  -> sim/run_top_lenet.sh, results/make_top1' \
		'  make top8      COUNT=8  -> sim/run_top_lenet.sh, results/make_top8' \
		'  make top16     COUNT=16 -> sim/run_top_lenet.sh, predicted_class, results/make_top16' \
		'  make top32     COUNT=32 -> sim/run_top_lenet.sh, predicted_class, results/make_top32' \
		'' \
		'Subsystem replay (cross-check entry):' \
		'  make subsystem8      COUNT=8 -> sim/run_lenet_fixture.sh, results/make_subsystem8' \
		'  make fullset-subsystem        -> candidate-final chunked subsystem full-set' \
		'  make fullset-subsystem-status -> merge existing chunks and print progress' \
		'' \
		'Performance replay (accuracy-only replay with perf reads enabled):' \
		'  make perf-top16      COUNT=16 -> sim/run_top_lenet.sh, results/make_perf_top16' \
		'  make perf-top32      COUNT=32 -> sim/run_top_lenet.sh, results/make_perf_top32' \
		'  make perf-subsystem8 COUNT=8  -> sim/run_lenet_fixture.sh, results/make_perf_subsystem8' \
		'' \
		'Utility checks:' \
		'  make sim-all    -> bash sim/run_sim.sh all' \
		'  make lint-sh    -> bash -n on formal shell entry scripts' \
		'  make diffcheck  -> git diff --check' \
		'' \
		'Common overrides:' \
		'  SIMULATOR=vcs|iverilog TIMEOUT_SECS=900 TOP_EXPECTED_FIELD=predicted_class'

top1:
	$(call run_top_batch,1,make_top1,results/make_top1)

top8:
	$(call run_top_batch,8,make_top8,results/make_top8)

top16:
	$(call run_top_batch,16,make_top16,results/make_top16)

top32:
	$(call run_top_batch,32,make_top32,results/make_top32)

subsystem8:
	$(call run_subsystem_batch,8,make_subsystem8,results/make_subsystem8)

perf-top16:
	$(call run_top_perf,16,make_perf_top16,results/make_perf_top16)

perf-top32:
	$(call run_top_perf,32,make_perf_top32,results/make_perf_top32)

perf-subsystem8:
	$(call run_subsystem_perf,8,make_perf_subsystem8,results/make_perf_subsystem8)

fullset-subsystem:
	bash scripts/run_w3_subsystem_full.sh run

fullset-subsystem-status:
	bash scripts/run_w3_subsystem_full.sh status

sim-all:
	bash sim/run_sim.sh all

lint-sh:
	@bash -n sim/run_top_lenet.sh
	@bash -n sim/run_lenet_fixture.sh
	@bash -n sim/run_sim.sh
	@bash -n scripts/run_w3_subsystem_chunked.sh
	@bash -n scripts/run_w3_subsystem_full.sh

diffcheck:
	@git diff --check
