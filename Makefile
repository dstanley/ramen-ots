IMG ?= ramen-ots:dev

.PHONY: build
build:
	go build -o bin/ramen-ots ./cmd/

.PHONY: test
test:
	go test ./... -v

.PHONY: fmt
fmt:
	go fmt ./...

.PHONY: vet
vet:
	go vet ./...

.PHONY: docker-build
docker-build:
	docker build -t $(IMG) .

.PHONY: docker-push
docker-push:
	docker push $(IMG)

.PHONY: run
run:
	go run ./cmd/ --fallback-kubeconfig=$(KUBECONFIG)

.PHONY: clean
clean:
	rm -rf bin/
