MAIN_PG_PATH := main/pg
MAIN_MYSQL_PATH := main/mysql
MAIN_SQLSERVER_PATH := main/sqlserver
MAIN_REDIS_PATH := main/redis
MAIN_MONGO_PATH := main/mongo
MAIN_FDB_PATH := main/fdb
MAIN_GP_PATH := main/gp
MAIN_ETCD_PATH := main/etcd
DOCKER_COMMON := golang ubuntu ubuntu_20_04 s3
CMD_FILES = $(wildcard cmd/**/*.go)
PKG_FILES = $(wildcard internal/**/*.go internal/**/**/*.go internal/*.go)
TEST_FILES = $(wildcard test/*.go testtools/*.go)
PKG := github.com/wal-g/wal-g
COVERAGE_FILE := coverage.out
TEST := "pg_tests"
MYSQL_TEST := "mysql_base_tests"
MONGO_MAJOR ?= "5.0"
MONGO_VERSION ?= "5.0.21"
MONGO_PACKAGE ?= "mongodb-org"
MONGO_REPO ?= "repo.mongodb.org"
GOLANGCI_LINT_VERSION ?= "v1.57"
REDIS_VERSION ?= "6.2.4"
TOOLS_MOD_DIR := ./internal/tools
MOCKS_DESTINATION := ./testtools/mocks
FILE_TO_MOCKS := ./internal/uploader.go ##перечисление путей до интерфейсов

BUILD_TAGS:=

ifdef USE_BROTLI
	BUILD_TAGS:=$(BUILD_TAGS) brotli
endif

ifdef USE_LIBSODIUM
	BUILD_TAGS:=$(BUILD_TAGS) libsodium
endif

ifdef USE_LZO
	BUILD_TAGS:=$(BUILD_TAGS) lzo
endif

.PHONY: unittest fmt lint clean install_tools

test: deps unittest pg_build mysql_build redis_build mongo_build gp_build unlink_brotli pg_integration_test mysql_integration_test redis_integration_test fdb_integration_test gp_integration_test etcd_integration_test

pg_test: deps pg_build unlink_brotli pg_integration_test

pg_build: $(CMD_FILES) $(PKG_FILES)
	(cd $(MAIN_PG_PATH) && go build -mod vendor -tags "$(BUILD_TAGS)" -o wal-g -ldflags "-s -w -X github.com/wal-g/wal-g/cmd/pg.buildDate=`date -u +%Y.%m.%d_%H:%M:%S` -X github.com/wal-g/wal-g/cmd/pg.gitRevision=`git rev-parse --short HEAD` -X github.com/wal-g/wal-g/cmd/pg.walgVersion=`git tag -l --points-at HEAD`")

install_and_build_pg: deps pg_build

pg_build_image:
	# There are dependencies between container images.
	# Running in one command leads to using outdated images and fails on clean system.
	# It can not be fixed with depends_on in compose file. https://github.com/docker/compose/issues/6332
	docker compose build $(DOCKER_COMMON)
	docker compose build pg
	docker compose build pg_build_docker_prefix

pg_save_image: install_and_build_pg pg_build_image
	mkdir -p ${CACHE_FOLDER}
	sudo rm -rf ${CACHE_FOLDER}/*
	docker save ${IMAGE} | gzip -c > ${CACHE_FILE_DOCKER_PREFIX}
	docker save ${IMAGE_UBUNTU_18_04} | gzip -c > ${CACHE_FILE_UBUNTU_18_04}
	docker save ${IMAGE_UBUNTU_20_04} | gzip -c > ${CACHE_FILE_UBUNTU_20_04}
	docker save ${IMAGE_GOLANG} | gzip -c > ${CACHE_FILE_GOLANG}
	ls ${CACHE_FOLDER}

pg_integration_test: clean_compose
	@if [ "x" = "${CACHE_FILE_DOCKER_PREFIX}x" ]; then\
		echo "Rebuild";\
		make install_and_build_pg;\
		make pg_build_image;\
	else\
		docker load -i ${CACHE_FILE_DOCKER_PREFIX};\
	fi
	@if echo "$(TEST)" | grep -Fqe "pgbackrest"; then\
		docker compose build pg_pgbackrest;\
	fi
	@if echo "$(TEST)" | grep -Fqe "pg_ssh_"; then\
		docker compose build ssh;\
	fi

	docker compose up --exit-code-from $(TEST) $(TEST)
	# Run tests with dependencies if we run all tests
	@if [ "$(TEST)" = "pg_tests" ]; then\
		docker compose build pg_pgbackrest ssh swift pg_wal_perftest_with_throttling &&\
		docker compose up --exit-code-from pg_ssh_backup_test pg_ssh_backup_test &&\
		docker compose up --exit-code-from pg_storage_swift_test pg_storage_swift_test &&\
		docker compose up --exit-code-from pg_storage_ssh_test pg_storage_ssh_test &&\
		docker compose up --exit-code-from pg_pgbackrest_backup_fetch_test pg_pgbackrest_backup_fetch_test &&\
		docker compose down &&\
		sleep 5 &&\
		docker compose up --exit-code-from pg_wal_perftest_with_throttling pg_wal_perftest_with_throttling ;\
	fi
	make clean_compose

.PHONY: clean_compose
clean_compose:
	services=$$(docker compose ps -a --format '{{.Name}} {{.Service}}' | grep wal-g_ | cut -w -f 2); \
		if [ "$$services" ]; then docker compose down $$services; fi

all_unittests: deps unittest

# todo Should we remove this target as a duplicate of pg_integration_test?
pg_int_tests_only:
	docker compose build pg_tests
	docker compose up --exit-code-from pg_tests pg_tests

pg_clean:
	(cd $(MAIN_PG_PATH) && go clean)
	./cleanup.sh

pg_install: pg_build
	mv $(MAIN_PG_PATH)/wal-g $(GOBIN)/wal-g

mysql_base: deps mysql_build unlink_brotli
mysql_test: deps mysql_build unlink_brotli mysql_integration_test

mysql_build: $(CMD_FILES) $(PKG_FILES)
	(cd $(MAIN_MYSQL_PATH) && go build -mod vendor -tags "$(BUILD_TAGS)" -o wal-g -ldflags "-s -w -X github.com/wal-g/wal-g/cmd/mysql.buildDate=`date -u +%Y.%m.%d_%H:%M:%S` -X github.com/wal-g/wal-g/cmd/mysql.gitRevision=`git rev-parse --short HEAD` -X github.com/wal-g/wal-g/cmd/mysql.walgVersion=`git tag -l --points-at HEAD`")

sqlserver_build: $(CMD_FILES) $(PKG_FILES)
	(cd $(MAIN_SQLSERVER_PATH) && go build -mod vendor -tags "$(BUILD_TAGS)" -o wal-g -ldflags "-s -w -X github.com/wal-g/wal-g/cmd/sqlserver.buildDate=`date -u +%Y.%m.%d_%H:%M:%S` -X github.com/wal-g/wal-g/cmd/sqlserver.gitRevision=`git rev-parse --short HEAD` -X github.com/wal-g/wal-g/cmd/sqlserver.walgVersion=`git tag -l --points-at HEAD`")

load_docker_common:
	@if [ "x" = "${CACHE_FOLDER}x" ]; then\
		echo "Rebuild";\
		docker compose build $(DOCKER_COMMON);\
	else\
		docker load -i ${CACHE_FILE_UBUNTU_18_04};\
		docker load -i ${CACHE_FILE_UBUNTU_20_04};\
		docker load -i ${CACHE_FILE_GOLANG};\
	fi

mysql_integration_test: deps mysql_build unlink_brotli load_docker_common
	./link_brotli.sh
	docker compose build mysql && docker compose build $(MYSQL_TEST)
	docker compose up --force-recreate --exit-code-from $(MYSQL_TEST) $(MYSQL_TEST)

mysql_clean:
	(cd $(MAIN_MYSQL_PATH) && go clean)
	./cleanup.sh

mysql_install: mysql_build
	mv $(MAIN_MYSQL_PATH)/wal-g $(GOBIN)/wal-g

mariadb_test: deps mysql_build unlink_brotli mariadb_integration_test

mariadb_integration_test: unlink_brotli load_docker_common
	./link_brotli.sh
	docker compose build mariadb && docker compose build mariadb_tests
	docker compose up --force-recreate --exit-code-from mariadb_tests mariadb_tests

mongo_test: deps mongo_build unlink_brotli

mongo_build: $(CMD_FILES) $(PKG_FILES)
	(cd $(MAIN_MONGO_PATH) && go build $(BUILD_ARGS) -mod vendor -tags "$(BUILD_TAGS)" -o wal-g -ldflags "-s -w -X github.com/wal-g/wal-g/cmd/mongo.buildDate=`date -u +%Y.%m.%d_%H:%M:%S` -X github.com/wal-g/wal-g/cmd/mongo.gitRevision=`git rev-parse --short HEAD` -X github.com/wal-g/wal-g/cmd/mongo.walgVersion=`git tag -l --points-at HEAD`")

mongo_install: mongo_build
	mv $(MAIN_MONGO_PATH)/wal-g $(GOBIN)/wal-g

mongo_features:
	set -e
	make go_deps
	cd tests_func/ && MONGO_MAJOR=$(MONGO_MAJOR) MONGO_VERSION=$(MONGO_VERSION) MONGO_PACKAGE=$(MONGO_PACKAGE) MONGO_REPO=$(MONGO_REPO) go test -v -count=1 -timeout 20m  --tf.test=true --tf.debug=true --tf.clean=true --tf.stop=true --tf.database=mongodb

clean_mongo_features:
	set -e
	cd tests_func/ && MONGO_MAJOR=$(MONGO_MAJOR) MONGO_VERSION=$(MONGO_VERSION) MONGO_PACKAGE=$(MONGO_PACKAGE) MONGO_REPO=$(MONGO_REPO) go test -v -count=1  -timeout 5m --tf.test=false --tf.debug=false --tf.clean=true --tf.stop=true --tf.database=mongodb

fdb_build: $(CMD_FILES) $(PKG_FILES)
	(cd $(MAIN_FDB_PATH) && go build -mod vendor -tags "$(BUILD_TAGS)" -o wal-g -ldflags "-s -w")

fdb_install: fdb_build
	mv $(MAIN_FDB_PATH)/wal-g $(GOBIN)/wal-g

fdb_integration_test: load_docker_common
	docker compose down -v
	docker compose build fdb_tests
	docker compose up --force-recreate --renew-anon-volumes --exit-code-from fdb_tests fdb_tests

redis_test: deps redis_build unlink_brotli redis_integration_test

redis_build: $(CMD_FILES) $(PKG_FILES)
	(cd $(MAIN_REDIS_PATH) && go build -mod vendor -tags "$(BUILD_TAGS)" -o wal-g -ldflags "-s -w -X github.com/wal-g/wal-g/cmd/redis.buildDate=`date -u +%Y.%m.%d_%H:%M:%S` -X github.com/wal-g/wal-g/cmd/redis.gitRevision=`git rev-parse --short HEAD` -X github.com/wal-g/wal-g/cmd/redis.walgVersion=`git tag -l --points-at HEAD`")

redis_integration_test: load_docker_common
	docker compose build redis && docker compose build redis_tests
	docker compose up --exit-code-from redis_tests redis_tests

redis_clean:
	(cd $(MAIN_REDIS_PATH) && go clean)
	./cleanup.sh

redis_install: redis_build
	mv $(MAIN_REDIS_PATH)/wal-g $(GOBIN)/wal-g

redis_features:
	set -e
	make go_deps
	cd tests_func/ && REDIS_VERSION=$(REDIS_VERSION) go test -v -count=1 -timeout 20m  --tf.test=true --tf.debug=false --tf.clean=true --tf.stop=true --tf.database=redis

clean_redis_features:
	set -e
	cd tests_func/ && REDIS_VERSION=$(REDIS_VERSION) go test -v -count=1  -timeout 5m --tf.test=false --tf.debug=false --tf.clean=true --tf.stop=true --tf.database=redis

etcd_test: deps etcd_build unlink_brotli etcd_integration_test

etcd_build: $(CMD_FILES) $(PKG_FILES)
	(cd $(MAIN_ETCD_PATH) && go build -mod vendor -tags "$(BUILD_TAGS)" -o wal-g -ldflags "-s -w -X github.com/wal-g/wal-g/cmd/etcd.buildDate=`date -u +%Y.%m.%d_%H:%M:%S` -X github.com/wal-g/wal-g/cmd/etcd.gitRevision=`git rev-parse --short HEAD` -X github.com/wal-g/wal-g/cmd/etcd.walgVersion=`git tag -l --points-at HEAD`")

etcd_install: etcd_build
	mv $(MAIN_ETCD_PATH)/wal-g $(GOBIN)/wal-g

etcd_clean:
	(cd $(MAIN_ETCD_PATH) && go clean)
	./cleanup.sh

# refactor
etcd_integration_test: load_docker_common
	docker compose build etcd etcd_tests
	docker compose up --exit-code-from etcd_tests etcd_tests

gp_build: $(CMD_FILES) $(PKG_FILES)
	(cd $(MAIN_GP_PATH) && go build -mod vendor -tags "$(BUILD_TAGS)" -o wal-g -ldflags "-s -w -X github.com/wal-g/wal-g/cmd/gp.buildDate=`date -u +%Y.%m.%d_%H:%M:%S` -X github.com/wal-g/wal-g/cmd/gp.gitRevision=`git rev-parse --short HEAD` -X github.com/wal-g/wal-g/cmd/gp.walgVersion=`git tag -l --points-at HEAD`")

gp_clean:
	(cd $(MAIN_GP_PATH) && go clean)
	./cleanup.sh

gp_install: gp_build
	mv $(MAIN_GP_PATH)/wal-g $(GOBIN)/wal-g

gp_test: deps gp_build unlink_brotli gp_integration_test

gp_integration_test: load_docker_common
	docker compose build gp gp_tests
	docker compose up --exit-code-from gp_tests gp_tests

st_test: deps pg_build unlink_brotli st_integration_test

st_integration_test: load_docker_common
	docker compose build st_tests
	docker compose up --exit-code-from st_tests st_tests

unittest:
	go list ./... | grep -Ev 'vendor|submodules|tmp' | xargs go vet
	go test -mod vendor -v $(TEST_MODIFIER) -tags "$(BUILD_TAGS)" ./internal/...
	go test -mod vendor -v $(TEST_MODIFIER) -tags "$(BUILD_TAGS)" ./pkg/...
	go test -mod vendor -v $(TEST_MODIFIER) -tags "$(BUILD_TAGS)" ./utility/...

coverage:
	go list ./... | grep -Ev 'vendor|submodules|tmp' | xargs go test -v $(TEST_MODIFIER) -coverprofile=$(COVERAGE_FILE) | grep -v 'no test files'
	go tool cover -html=$(COVERAGE_FILE)

install_tools:
	cd $(TOOLS_MOD_DIR) && go install golang.org/x/tools/cmd/goimports
	$(warning Please run make docker_lint for lint. It is unreliable to use self-compiled golangci-lint. \
		https://golangci-lint.run/usage/install/#install-from-source)
	cd $(TOOLS_MOD_DIR) && go install github.com/golangci/golangci-lint/cmd/golangci-lint

fmt: $(CMD_FILES) $(PKG_FILES) $(TEST_FILES)
	gofmt -s -w $(CMD_FILES) $(PKG_FILES) $(TEST_FILES)

goimports: install_tools $(CMD_FILES) $(PKG_FILES) $(TEST_FILES)
	goimports -w $(CMD_FILES) $(PKG_FILES) $(TEST_FILES)

lint: install_tools
	golangci-lint run --allow-parallel-runners ./...

docker_lint:
	docker build -t wal-g/lint --build-arg TAG=$(GOLANGCI_LINT_VERSION) - < docker/lint/Dockerfile
	docker run --rm -v `pwd`:/app \
		-v wal-g_lint_cache:/cache -e GOLANGCI_LINT_CACHE=/cache/lint \
		-e GOCACHE=/cache/go -e GOMODCACHE=/cache/gomod \
		wal-g/lint golangci-lint run -v

deps: go_deps link_external_deps

go_deps:
	git submodule update --init
	go mod vendor
ifdef USE_LZO
	sed -i 's|\(#cgo LDFLAGS:\) .*|\1 -Wl,-Bstatic -llzo2 -Wl,-Bdynamic|' vendor/github.com/cyberdelia/lzo/lzo.go
endif

link_external_deps: link_brotli link_libsodium

unlink_external_deps: unlink_brotli unlink_libsodium

install:
	@echo "Nothing to be done. Use pg_install/mysql_install/mongo_install/fdb_install/gp_install/etcd_install... instead."

link_brotli:
	@if [ -n "${USE_BROTLI}" ]; then ./link_brotli.sh; fi
	@if [ -z "${USE_BROTLI}" ]; then echo "info: USE_BROTLI is not set, skipping 'link_brotli' task"; fi

link_libsodium:
	@if [ ! -z "${USE_LIBSODIUM}" ]; then\
		./link_libsodium.sh;\
	fi

unlink_brotli:
	rm -rf vendor/github.com/google/brotli/*
	if [ -n "${USE_BROTLI}" ] ; then mv tmp/brotli/* vendor/github.com/google/brotli/; fi
	rm -rf tmp/brotli

unlink_libsodium:
	rm -rf tmp/libsodium

build_client:
	cd cmd/daemonclient && \
	go build -o ../../bin/walg-daemon-client -ldflags "-s -w -X main.buildDate=`date -u +%Y.%m.%d_%H:%M:%S` -X main.gitRevision=`git rev-parse --short HEAD` -X main.version=`git tag -l --points-at HEAD`"

.PHONY: mocks
# put the files with interfaces you'd like to mock in prerequisites
# wildcards are allowed
mocks: $(FILE_TO_MOCKS)
	@echo "Generating mocks..."
	@rm -rf $(MOCKS_DESTINATION)
	@for file in $^; do mockgen -source=$$file -destination=$(MOCKS_DESTINATION)/$$(basename $$file); done
