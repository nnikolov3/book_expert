# GO CODING STANDARD

## Overview

This document establishes comprehensive Go coding standards for projects, updated as of August 2025 to align with the latest Go best practices (Go 1.23 features, including improved generics and iterators). These standards emphasize **explicit behavior**, **robust error handling**, **maintainable code structure**, and **reliability focus**, while incorporating core design principles such as simplicity, modularity, correctness, and consistency. The refactor focuses on clarity, reduced redundancy, and integration of modern guidelines for readability, security, and performance. All code must adhere to these rules to ensure robustness, testability, and ease of maintenance.

## Core Principles

Integrate foundational design principles for simplicity and explicitness:

- **Explicit Over Implicit**: Make intentions clear through code structure and naming. Avoid hidden behaviors and magic constants. Prefer verbose clarity over clever brevity.
- **Composition Over Inheritance**: Use embedding and interfaces for code reuse. Design small, focused interfaces. Favor composition for extending behavior.
- **Error Handling Excellence**: Handle every error explicitly. Provide contextual error information. Use error wrapping to preserve call stack.
- **Simplicity and Clarity**: Strive for the simplest solution that meets requirements. Choose clear names and straightforward control flow over clever constructs. Avoid premature optimization.
- **Modularity and Abstraction**: Isolate responsibilities into small, composable units. Define clear boundaries and interfaces.
- **Correctness and Testing**: Treat tests as first-class citizens. Write tests before or alongside code. Validate inputs at boundaries.
- **Maintainability and Readability**: Keep functions short and focused. Remove dead code immediately. Follow consistent conventions.
- **Performance with Purpose**: Measure before optimizing. Reduce allocations in hot paths.
- **Consistency and Convention**: Follow established style guides rigorously.
- **Security and Safety**: Design for secure defaults. Validate and sanitize inputs.

## Package Management

### Package Organization

- Use lowercase, short, descriptive package names.
- Avoid generic names like `util` or `common`.
- One package per directory.

**Example**:

```go
// Good
package mqtt     // MQTT client functionality
package rag      // RAG service implementation

// Bad
package utils    // Too generic
```

### Import Organization

- Group imports: standard library first, third-party second, local last.
- Separate groups with blank lines.

**Example**:

```go
import (
    "context"
    "fmt"
    "time"

    "github.com/eclipse/paho.mqtt.golang"

    "github.com/niko/mqtt-agent-orchestration/internal/rag"
)
```

## Variable and Constant Declaration

### Naming Conventions

- Use camelCase for variables and functions.
- Use PascalCase for exported types and functions.
- Use ALL_CAPS for constants.
- Add context to names in large scopes.

**Example**:

```go
const (
    DefaultConnectionTimeout = 30 * time.Second
    MaxRetryAttempts         = 3
)

type WorkflowOrchestrator struct {
    mqttClient mqtt.ClientInterface
}
```

### Variable Scope and Declaration

- Declare variables close to usage.
- Use short names in small scopes, descriptive in large scopes.
- Initialize explicitly.

**Example**:

```go
func ProcessBatch(ctx context.Context, items []Item) error {
    const batchSize = 100
    totalItems := len(items)
    processedCount := 0

    for i := 0; i < totalItems; i += batchSize {
        endIndex := min(i + batchSize, totalItems)
        batch := items[i:endIndex]
        if err := processBatch(ctx, batch); err != nil {
            return fmt.Errorf("failed batch %d-%d: %w", i, endIndex-1, err)
        }
        processedCount += len(batch)
    }
    return nil
}
```

## Function and Method Design

### Function Signatures

- Keep parameter lists short.
- Use context as first parameter for cancellable operations.
- Return errors last.
- Use named returns for complex functions.

**Example**:

```go
func PublishMessage(ctx context.Context, topic string, payload []byte, qos byte) error {
    if ctx == nil || topic == "" || len(payload) == 0 {
        return fmt.Errorf("invalid input")
    }
    return publish(ctx, topic, payload, qos)
}
```

### Method Receivers

- Use pointer receivers for modifications or large structs.
- Be consistent within a type.

**Example**:

```go
type WorkflowState struct {
    mu sync.RWMutex
    // fields...
}

func (w *WorkflowState) UpdateStatus(newStatus string) {
    w.mu.Lock()
    defer w.mu.Unlock()
    // update...
}
```

## Error Handling Patterns

### Error Types and Wrapping

- Create custom error types for domains.
- Use wrapping for context.
- Implement `Unwrap` and `Is` for checking.

**Example**:

```go
type WorkflowError struct {
    WorkflowID string
    Cause      error
}

func (e *WorkflowError) Error() string { return fmt.Sprintf("workflow %s: %v", e.WorkflowID, e.Cause) }
func (e *WorkflowError) Unwrap() error { return e.Cause }
```

### Error Checking Patterns

- Check errors immediately.
- Use early returns.
- Validate inputs.

**Example**:

```go
func ConnectAndSubscribe(ctx context.Context, topics []string) error {
    if len(topics) == 0 {
        return fmt.Errorf("no topics")
    }
    if err := Connect(ctx); err != nil {
        return fmt.Errorf("connect failed: %w", err)
    }
    // subscribe...
    return nil
}
```

## Struct and Interface Design

### Interface Design

- Keep small and focused.
- Define at point of use.
- Compose larger interfaces.

**Example**:

```go
type TaskProcessor interface {
    ProcessTask(ctx context.Context, task Task) (string, error)
}

type FullTaskHandler interface {
    TaskProcessor
    // other interfaces...
}
```

### Struct Design

- Group related fields.
- Use embedding.
- Include mutex for concurrency.

**Example**:

```go
type BaseWorker struct {
    mu sync.RWMutex
    // fields...
}

type RoleBasedWorker struct {
    BaseWorker
    // role-specific...
}
```

## Concurrency Patterns

### Goroutines and Channels

- Use channels for communication.
- Close channels at sender.
- Use context for cancellation.

**Example**:

```go
func (mp *MessageProcessor) worker(id int) {
    defer mp.wg.Done()
    for {
        select {
        case msg, ok := <-mp.inputChan:
            if !ok {
                return
            }
            // process...
        case <-mp.ctx.Done():
            return
        }
    }
}
```

### Context Usage

- Pass as first parameter.
- Use for cancellation and deadlines.

**Example**:

```go
func ProcessWithTimeout(ctx context.Context, data []byte, timeout time.Duration) error {
    timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
    defer cancel()
    // process...
    return nil
}
```

## Testing Standards

### Table-Driven Tests

- Use for multiple scenarios.
- Include positive and negative cases.

**Example**:

```go
func TestGetNextStage(t *testing.T) {
    tests := []struct {
        name     string
        // fields...
    }{
        // cases...
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // assertions...
        })
    }
}
```

### Mock and Interface Testing

- Use interfaces for dependencies.
- Inject mocks.

**Example**:

```go
type MockMQTTClient struct {
    // mocks...
}

func TestExecuteStage(t *testing.T) {
    mock := &MockMQTTClient{}
    // test...
}
```

## Code Organization

### Directory Structure

- Follow Go project layout.
- Separate internal and public packages.

```
.
├── cmd/          # Entry points
├── internal/     # Private code
├── pkg/          # Public code
└── testdata/     # Tests
```

### File Organization

- One main type per file.
- Group related functions.

## Performance Guidelines

### Memory Management

- Minimize allocations.
- Use sync.Pool.

**Example**:

```go
var bufferPool = sync.Pool{
    New: func() interface{} { return make([]byte, 0, 1024) },
}
```

### String Operations

- Use strings.Builder.
- Pre-allocate capacity.

**Example**:

```go
func BuildLogMessage(level, message string) string {
    var b strings.Builder
    b.Grow(len(level) + len(message) + 10)
    // build...
    return b.String()
}
```

## Documentation Standards

### Package Documentation

- Explain purpose and usage.
- Provide examples.

**Example**:
// Package rag provides RAG capabilities.
// Usage:
// service := rag.NewService(...)

### Function Documentation

- Use godoc format.
- Include params, returns, examples.

## Security Guidelines

### Input Validation

- Validate at boundaries.
- Use whitelists.

**Example**:

```go
func CreateWorkflow(ctx context.Context, req *CreateWorkflowRequest) (*Workflow, error) {
    if req == nil || !validateWorkflowType(req.Type) {
        return nil, fmt.Errorf("invalid request")
    }
    // process...
}
```

### Secret Management

- Use environment variables.
- Never log secrets.

**Example**:

```go
func LoadConfig() (*Config, error) {
    apiKey := os.Getenv("API_KEY")
    if apiKey == "" {
        return nil, fmt.Errorf("missing API_KEY")
    }
    // ...
}
```

## Compliance Checklist

- [ ] Functions have descriptive names.
- [ ] Errors handled explicitly.
- [ ] Interfaces small and focused.
- [ ] Tests cover all cases.
- [ ] Documentation up-to-date.
- [ ] Inputs validated.
- [ ] No hardcoded values.
- [ ] Code passes go vet, golint, and staticcheck.
