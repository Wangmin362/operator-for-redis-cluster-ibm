ARTIFACT_OPERATOR=redis-operator
ARTIFACT_INITCONTAINER=init-container

PREFIX=172.22.175.150/devops/redis-

SOURCES := $(shell find . ! -name "*_test.go" -name '*.go')

CMDBINS := operator node metrics
CRD_OPTIONS ?= "crd:crdVersions=v1,generateEmbeddedObjectMeta=true"

ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# TAG?=$(shell git tag|tail -1)
TAG=latest
REDIS_VERSION=6.2.5
COMMIT=$(shell git rev-parse HEAD)
DATE=$(shell date +%Y-%m-%d/%H:%M:%S)
BUILDINFOPKG=github.com/IBM/operator-for-redis-cluster/pkg/utils
LDFLAGS= -ldflags "-w -X ${BUILDINFOPKG}.TAG=${TAG} -X ${BUILDINFOPKG}.COMMIT=${COMMIT} -X ${BUILDINFOPKG}.OPERATOR_VERSION=${OPERATOR_VERSION} -X ${BUILDINFOPKG}.REDIS_VERSION=${REDIS_VERSION} -X ${BUILDINFOPKG}.BUILDTIME=${DATE} -s"

all: build

plugin: build-kubectl-rc install-plugin

install-plugin:
	./tools/install-plugin.sh

build-%:
	CGO_ENABLED=0 GOOS=linux go build -installsuffix cgo ${LDFLAGS} -o bin/$* ./cmd/$*

buildlinux-%: ${SOURCES}
	CGO_ENABLED=0 GOOS=linux go build -installsuffix cgo ${LDFLAGS} -o docker/$*/$* ./cmd/$*/main.go

container-%: buildlinux-%
	docker build -t $(PREFIX)$*:$(TAG) -f Dockerfile.$* .

build: $(addprefix build-,$(CMDBINS))

buildlinux: $(addprefix buildlinux-,$(CMDBINS))

container: $(addprefix container-,$(CMDBINS))

manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role output:rbac:none paths="./..." output:crd:artifacts:config=charts/redis-operator/crds/

generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object paths="./..."

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.9.2 ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

# 产生资源清单文件
.PHONY: gen-deploy
gen-deploy: generate manifests
	helm template --debug redis charts/redis-operator -n redis-system-ibm > deploy/operator/redis-operator.yaml
	/usr/bin/cp -f charts/redis-operator/crds/db.ibm.com_redisclusters.yaml deploy/operator/db.ibm.com_redisclusters.yaml
	helm template --debug redis charts/redis-cluster  -n redis-system-ibm > deploy/sample/redis-cluster.yaml

# 部署operator
.PHONY: install-operator
install-operator:
	-kubectl create -f deploy/operator/db.ibm.com_redisclusters.yaml
	-kubectl create -f deploy/operator/redis-operator.yaml

# 卸载operator
.PHONY: uninstall-operator
uninstall-operator:
	-kubectl delete -f deploy/operator/redis-operator.yaml
	-kubectl delete -f deploy/operator/db.ibm.com_redisclusters.yaml

# 部署redis-cluster
.PHONY: install-redis
install-redis:
	kubectl create -f deploy/sample/redis-cluster.yaml

# 卸载redis-clusetr
.PHONY: uninstall-redis
uninstall-redis:
	kubectl delete -f deploy/sample/redis-cluster.yaml


test:
	./go.test.sh

push-%: container-%
	docker push $(PREFIX)$*:$(TAG)

push: $(addprefix push-,$(CMDBINS))

clean:
	rm -f ${ARTIFACT_OPERATOR}

# gofmt and goimports all go files
fmt:
	find . -name '*.go' -not -wholename './vendor/*' | while read -r file; do gofmt -w -s "$$file"; goimports -w "$$file"; done
.PHONY: fmt

# Run all the linters
lint:
	golangci-lint run --enable exportloopref
.PHONY: lint

.PHONY: build push clean test
