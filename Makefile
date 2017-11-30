SHELL=/bin/bash

export GIT_BRANCH ?= 6.0

ifndef ELASTIC_VERSION
export ELASTIC_VERSION := $(shell ./bin/elastic-version)
endif

ifdef STAGING_BUILD_NUM
export VERSION_TAG := $(ELASTIC_VERSION)-$(STAGING_BUILD_NUM)
DOWNLOAD_URL_ROOT ?= https://staging.elastic.co/$(VERSION_TAG)/downloads/beats
else
export VERSION_TAG := $(ELASTIC_VERSION)
DOWNLOAD_URL_ROOT ?= https://artifacts.elastic.co/downloads/beats
endif

BEATS := $(shell cat beats.txt)
REGISTRY ?= docker.elastic.co
HTTPD ?= beats-docker-artifact-server

# Make sure we run local versions of everything, particularly commands
# installed into our virtualenv with pip eg. `docker-compose`.
export PATH := ./bin:./venv/bin:$(PATH)

all: venv images docker-compose.yml test

# Run the tests with testinfra (actually our custom wrapper at ./bin/testinfra)
# REF: http://testinfra.readthedocs.io/en/latest/
test: lint all
	bin/pytest -v tests/
.PHONY: test

lint: venv
	flake8 tests/

docker-compose.yml: venv
	jinja2 \
	  -D beats='$(BEATS)' \
	  -D version=$(VERSION_TAG) \
	  -D registry=$(REGISTRY) \
	  templates/docker-compose.yml.j2 > docker-compose.yml
.PHONY: docker-compose.yml

# Bring up a full-stack demo with Elasticsearch, Kibana and all the Unix Beats.
# Point a browser at http://localhost:5601 to see the results, and log in to
# to Kibana with "elastic"/"changeme".
demo: all
	docker-compose up

# Build images for all the Beats, generate the Dockerfiles as we go.
images: $(BEATS)
$(BEATS): venv
	mkdir -p build/$@/config
	touch build/$@/config/$@.yml
	jinja2 \
	  -D beat=$@ \
	  -D version=$(ELASTIC_VERSION) \
	  -D url=$(DOWNLOAD_URL_ROOT)/$@/$@-$(ELASTIC_VERSION)-linux-x86_64.tar.gz \
          templates/Dockerfile.j2 > build/$@/Dockerfile
	jinja2 \
	  -D beat=$@ \
	  -D version=$(ELASTIC_VERSION) \
	  templates/docker-entrypoint.j2 > build/$@/docker-entrypoint
	chmod +x build/$@/docker-entrypoint
	docker build $(DOCKER_FLAGS) --tag=$(REGISTRY)/beats/$@:$(VERSION_TAG) build/$@

local-httpd:
	docker run --rm -d --name=$(HTTPD) --network=host \
	  -v $(ARTIFACTS_DIR):/mnt \
	  python:3 bash -c 'cd /mnt && python3 -m http.server'
	timeout 120 bash -c 'until curl -s localhost:8000 > /dev/null; do sleep 1; done'

release-manager-snapshot: local-httpd
	ELASTIC_VERSION=$(ELASTIC_VERSION)-SNAPSHOT \
	  DOWNLOAD_URL_ROOT=http://localhost:8000/beats/build/upload \
	  DOCKER_FLAGS='--network=host' \
	  make images || (docker kill $(HTTPD); false)
	-docker kill $(HTTPD)
release-manager-release: local-httpd
	ELASTIC_VERSION=$(ELASTIC_VERSION) \
	  DOWNLOAD_URL_ROOT=http://localhost:8000/beats/build/upload \
	  DOCKER_FLAGS='--network=host' \
	  make images || (docker kill $(HTTPD); false)
	-docker kill $(HTTPD)

# Push the images to the dedicated push endpoint at "push.docker.elastic.co"
push: all
	for beat in $(BEATS); do \
	  docker tag $(REGISTRY)/beats/$$beat:$(VERSION_TAG) push.$(REGISTRY)/beats/$$beat:$(VERSION_TAG); \
	  docker push push.$(REGISTRY)/beats/$$beat:$(VERSION_TAG); \
	  docker rmi push.$(REGISTRY)/beats/$$beat:$(VERSION_TAG); \
	done

venv: requirements.txt
	test -d venv || virtualenv --python=python3.5 venv
	pip install -r requirements.txt
	touch venv

clean: venv
	docker-compose down -v || true
	rm -f docker-compose.yml build/*/Dockerfile build/*/config/*.sh build/*/docker-entrypoint
	rm -rf venv
	find . -name __pycache__ | xargs rm -rf
