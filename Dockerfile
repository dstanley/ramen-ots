# Build stage
FROM registry.suse.com/bci/golang:1.24 AS builder
WORKDIR /workspace

COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ cmd/
COPY internal/ internal/

RUN CGO_ENABLED=0 GOOS=linux go build -o ramen-ots ./cmd/

# Runtime stage
FROM registry.suse.com/bci/bci-micro:15.6
WORKDIR /
COPY --from=builder /workspace/ramen-ots .
USER 65532:65532
ENTRYPOINT ["/ramen-ots"]
