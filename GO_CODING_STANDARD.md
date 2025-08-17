# Go Coding Standard

## Overview

This document establishes comprehensive Go coding standards for projects developed with Claude Code. These standards emphasize **explicit behavior**, **robust error handling**, **maintainable code structure**, and **reliability focus**.

## Core Principles

### 1. Explicit Over Implicit

- Make intentions clear through code structure and naming
- Avoid hidden behaviors and magic constants
- Prefer verbose clarity over clever brevity

```go
// GOOD: Explicit intent and clear flow
func (c *Client) ConnectWithRetry(ctx context.Context, maxRetries int) error {
    const baseDelay = time.Second

    for attempt := 1; attempt <= maxRetries; attempt++ {
        if err := c.connect(ctx); err != nil {
            if attempt == maxRetries {
                return fmt.Errorf("connection failed after %d attempts: %w", maxRetries, err)
            }

            delay := time.Duration(attempt) * baseDelay
            log.Printf("Connection attempt %d failed, retrying in %v: %v", attempt, delay, err)

            select {
            case <-time.After(delay):
                continue
            case <-ctx.Done():
                return ctx.Err()
            }
        }
        return nil
    }
    return fmt.Errorf("unreachable code")
}

// BAD: Implicit behavior and magic numbers
func (c *Client) Connect(ctx context.Context) error {
    for i := 0; i < 3; i++ {
        if err := c.connect(ctx); err == nil {
            return nil
        }
        time.Sleep(time.Duration(i+1) * time.Second)
    }
    return errors.New("failed")
}
```

### 2. Composition Over Inheritance

- Use embedding and interfaces for code reuse
- Design small, focused interfaces
- Favor composition for extending behavior

```go
// GOOD: Composition with clear interfaces
type Logger interface {
    Log(level string, message string)
}

type MetricsCollector interface {
    Increment(metric string)
}

type Service struct {
    logger  Logger
    metrics MetricsCollector
    config  *Config
}

func NewService(logger Logger, metrics MetricsCollector, config *Config) *Service {
    return &Service{
        logger:  logger,
        metrics: metrics,
        config:  config,
    }
}

// BAD: Trying to simulate inheritance
type BaseService struct {
    Logger
    MetricsCollector
}
```

### 3. Error Handling Excellence

- Handle every error explicitly
- Provide contextual error information
- Use error wrapping to preserve call stack

```go
// GOOD: Comprehensive error handling
func (s *Service) ProcessData(ctx context.Context, input []byte) (*Result, error) {
    if len(input) == 0 {
        return nil, fmt.Errorf("input cannot be empty")
    }

    data, err := s.parser.Parse(input)
    if err != nil {
        return nil, fmt.Errorf("failed to parse input data: %w", err)
    }

    result, err := s.processor.Process(ctx, data)
    if err != nil {
        s.metrics.Increment("processing_errors")
        return nil, fmt.Errorf("processing failed for data size %d: %w", len(input), err)
    }

    if err := s.validator.Validate(result); err != nil {
        return nil, fmt.Errorf("result validation failed: %w", err)
    }

    return result, nil
}

// BAD: Ignoring or poorly handling errors
func (s *Service) ProcessData(input []byte) *Result {
    data, _ := s.parser.Parse(input)  // Ignoring error
    result, err := s.processor.Process(context.Background(), data)
    if err != nil {
        panic(err)  // Not appropriate for library code
    }
    return result
}
```

## Package Management

### Package Organization

- One package per directory
- Package names should be lowercase, short, and descriptive
- Avoid generic names like `util`, `common`, `helpers`

```go
// GOOD: Descriptive package names
package mqtt     // MQTT client functionality
package rag      // RAG service implementation
package types    // Shared type definitions
package worker   // Worker orchestration

// BAD: Generic package names
package utils    // What kind of utilities?
package common   // Common what?
package helpers  // Helper functions for what?
```

### Import Organization

- Standard library imports first
- Third-party imports second
- Local imports last
- Use blank lines to separate groups

```go
// GOOD: Properly organized imports
package main

import (
    "context"
    "fmt"
    "time"

    "github.com/eclipse/paho.mqtt.golang"
    "github.com/qdrant/go-client/qdrant"

    "github.com/niko/mqtt-agent-orchestration/internal/rag"
    "github.com/niko/mqtt-agent-orchestration/pkg/types"
)

// BAD: Disorganized imports
import (
    "github.com/niko/mqtt-agent-orchestration/pkg/types"
    "fmt"
    "github.com/eclipse/paho.mqtt.golang"
    "context"
)
```

## Variable and Constant Declaration

### Naming Conventions

- Use camelCase for variables and functions
- Use PascalCase for exported types and functions
- Use ALL_CAPS for constants with clear, descriptive names
- Add context to variable names when scope is large

```go
// GOOD: Clear, contextual naming
const (
    DefaultConnectionTimeout = 30 * time.Second
    MaxRetryAttempts         = 3
    MQTTQualityOfService     = 1
)

type WorkflowOrchestrator struct {
    mqttClient      mqtt.ClientInterface
    workflows       map[string]*WorkflowState
    shutdownContext context.Context
    cancelFunc      context.CancelFunc
}

func (o *WorkflowOrchestrator) ProcessWorkflowTask(ctx context.Context, task *types.WorkflowTask) error {
    workflowID := task.WorkflowID
    currentStage := task.Stage

    existingWorkflow, workflowExists := o.workflows[workflowID]
    if !workflowExists {
        return fmt.Errorf("workflow not found: %s", workflowID)
    }

    // Process the task...
    return nil
}

// BAD: Unclear, abbreviated naming
const (
    TIMEOUT = 30  // Timeout for what?
    MAX     = 3   // Max what?
    QOS     = 1   // QOS of what?
)

func (o *WorkflowOrchestrator) Process(ctx context.Context, t *types.WorkflowTask) error {
    id := t.WorkflowID
    s := t.Stage

    w, ok := o.workflows[id]  // Unclear variable names
    if !ok {
        return fmt.Errorf("not found: %s", id)
    }

    return nil
}
```

### Variable Scope and Declaration

- Declare variables close to their usage
- Use short names in small scopes, descriptive names in large scopes
- Initialize variables explicitly

```go
// GOOD: Appropriate scoping and initialization
func (s *Service) ProcessBatch(ctx context.Context, items []Item) error {
    const batchSize = 100

    totalItems := len(items)
    processedCount := 0

    for i := 0; i < totalItems; i += batchSize {
        endIndex := i + batchSize
        if endIndex > totalItems {
            endIndex = totalItems
        }

        batch := items[i:endIndex]
        if err := s.processBatch(ctx, batch); err != nil {
            return fmt.Errorf("failed to process batch %d-%d: %w", i, endIndex-1, err)
        }

        processedCount += len(batch)
        s.logger.Debugf("Processed %d/%d items", processedCount, totalItems)
    }

    return nil
}

// BAD: Poor scoping and unclear initialization
var (
    count int  // Global scope for local use
    total int
)

func (s *Service) ProcessBatch(ctx context.Context, items []Item) error {
    total = len(items)  // Using global variables

    for i := 0; i < total; i += 100 {
        // Unclear batch handling
        end := i + 100
        if end > total {
            end = total
        }

        count += end - i
    }

    return nil
}
```

## Function and Method Design

### Function Signatures

- Keep parameter lists short and focused
- Use context as the first parameter for cancellable operations
- Return errors as the last return value
- Use named return values for complex functions

```go
// GOOD: Clear function signatures with proper context handling
func (c *Client) PublishMessage(ctx context.Context, topic string, payload []byte, qos byte) error {
    if ctx == nil {
        return fmt.Errorf("context cannot be nil")
    }

    if topic == "" {
        return fmt.Errorf("topic cannot be empty")
    }

    if len(payload) == 0 {
        return fmt.Errorf("payload cannot be empty")
    }

    return c.publish(ctx, topic, payload, qos)
}

func (p *Parser) ParseWorkflowConfig(data []byte) (config *WorkflowConfig, err error) {
    defer func() {
        if r := recover(); r != nil {
            config = nil
            err = fmt.Errorf("panic during parsing: %v", r)
        }
    }()

    // Parsing implementation...
    return config, nil
}

// BAD: Poor function design
func (c *Client) Publish(topic string, payload []byte, qos byte, timeout time.Duration, retry bool) error {
    // Too many parameters, missing context
    return nil
}

func Parse(data []byte) (*WorkflowConfig, error) {
    // Could panic without recovery
    return nil, nil
}
```

### Method Receivers

- Use pointer receivers for methods that modify the receiver
- Use pointer receivers for large structs to avoid copying
- Be consistent within a type (prefer all pointer or all value receivers)

```go
// GOOD: Consistent pointer receivers
type WorkflowState struct {
    ID           string
    Status       string
    CreatedAt    time.Time
    UpdatedAt    time.Time
    attempts     map[string]int
    mu           sync.RWMutex
}

func (w *WorkflowState) UpdateStatus(newStatus string) {
    w.mu.Lock()
    defer w.mu.Unlock()

    w.Status = newStatus
    w.UpdatedAt = time.Now()
}

func (w *WorkflowState) GetStatus() string {
    w.mu.RLock()
    defer w.mu.RUnlock()

    return w.Status
}

func (w *WorkflowState) IncrementAttempts(stage string) {
    w.mu.Lock()
    defer w.mu.Unlock()

    if w.attempts == nil {
        w.attempts = make(map[string]int)
    }
    w.attempts[stage]++
}

// BAD: Inconsistent receiver types
func (w WorkflowState) UpdateStatus(newStatus string) {  // Should be pointer
    w.Status = newStatus  // Won't actually update the original
}

func (w *WorkflowState) GetStatus() string {  // Could be value receiver
    return w.Status
}
```

## Error Handling Patterns

### Error Types and Wrapping

- Create custom error types for specific domains
- Use error wrapping to maintain context
- Implement error interfaces for type checking

```go
// GOOD: Structured error handling
type WorkflowError struct {
    WorkflowID string
    Stage      string
    Operation  string
    Cause      error
}

func (e *WorkflowError) Error() string {
    return fmt.Sprintf("workflow %s failed at stage %s during %s: %v",
        e.WorkflowID, e.Stage, e.Operation, e.Cause)
}

func (e *WorkflowError) Unwrap() error {
    return e.Cause
}

func (e *WorkflowError) Is(target error) bool {
    t, ok := target.(*WorkflowError)
    if !ok {
        return false
    }
    return e.WorkflowID == t.WorkflowID && e.Stage == t.Stage
}

// Usage with proper error handling
func (o *Orchestrator) executeStage(ctx context.Context, workflowID string, stage string) error {
    workflow, exists := o.workflows[workflowID]
    if !exists {
        return &WorkflowError{
            WorkflowID: workflowID,
            Stage:      stage,
            Operation:  "lookup",
            Cause:      fmt.Errorf("workflow not found"),
        }
    }

    if err := o.processStage(ctx, workflow, stage); err != nil {
        return &WorkflowError{
            WorkflowID: workflowID,
            Stage:      stage,
            Operation:  "processing",
            Cause:      err,
        }
    }

    return nil
}

// BAD: Generic error handling
func (o *Orchestrator) executeStage(ctx context.Context, workflowID string, stage string) error {
    workflow, exists := o.workflows[workflowID]
    if !exists {
        return errors.New("not found")  // No context
    }

    if err := o.processStage(ctx, workflow, stage); err != nil {
        return err  // No wrapping or context
    }

    return nil
}
```

### Error Checking Patterns

- Check errors immediately after operations
- Use early returns to reduce nesting
- Validate inputs at function boundaries

```go
// GOOD: Immediate error checking with early returns
func (c *Client) ConnectAndSubscribe(ctx context.Context, topics []string) error {
    if len(topics) == 0 {
        return fmt.Errorf("no topics provided for subscription")
    }

    // Connect first
    if err := c.Connect(ctx); err != nil {
        return fmt.Errorf("failed to connect before subscribing: %w", err)
    }

    // Subscribe to each topic
    for i, topic := range topics {
        if topic == "" {
            return fmt.Errorf("topic %d is empty", i)
        }

        if err := c.Subscribe(ctx, topic, c.defaultHandler); err != nil {
            // Try to clean up already subscribed topics
            for j := 0; j < i; j++ {
                if unsubErr := c.Unsubscribe(ctx, topics[j]); unsubErr != nil {
                    c.logger.Warnf("Failed to cleanup subscription %s: %v", topics[j], unsubErr)
                }
            }
            return fmt.Errorf("failed to subscribe to topic %s: %w", topic, err)
        }

        c.logger.Debugf("Successfully subscribed to topic: %s", topic)
    }

    c.logger.Infof("Successfully subscribed to %d topics", len(topics))
    return nil
}

// BAD: Poor error handling structure
func (c *Client) ConnectAndSubscribe(ctx context.Context, topics []string) error {
    if err := c.Connect(ctx); err != nil {
        if len(topics) > 0 {
            for _, topic := range topics {
                if topic != "" {
                    if err := c.Subscribe(ctx, topic, c.defaultHandler); err != nil {
                        return err  // Lost connection error context
                    }
                }
            }
        }
        return err
    }
    return nil
}
```

## Struct and Interface Design

### Interface Design

- Keep interfaces small and focused
- Define interfaces at the point of use, not implementation
- Use composition to build larger interfaces

```go
// GOOD: Small, focused interfaces
type TaskProcessor interface {
    ProcessTask(ctx context.Context, task Task) (string, error)
}

type TaskValidator interface {
    ValidateTask(task Task) error
}

type TaskStatusReporter interface {
    ReportStatus(taskID string, status TaskStatus) error
}

// Compose interfaces when needed
type FullTaskHandler interface {
    TaskProcessor
    TaskValidator
    TaskStatusReporter
}

// Defined at point of use
type WorkerService struct {
    processor TaskProcessor  // Only needs this interface
    validator TaskValidator  // And this one
}

func NewWorkerService(processor TaskProcessor, validator TaskValidator) *WorkerService {
    return &WorkerService{
        processor: processor,
        validator: validator,
    }
}

// BAD: Large, monolithic interface
type TaskHandler interface {
    ProcessTask(ctx context.Context, task Task) (string, error)
    ValidateTask(task Task) error
    ReportStatus(taskID string, status TaskStatus) error
    GetMetrics() TaskMetrics
    SetConfig(config TaskConfig) error
    StartHealthCheck() error
    StopHealthCheck() error
    // ... many more methods
}
```

### Struct Design

- Group related fields logically
- Use embedding for shared behavior
- Include mutex fields for concurrent access

```go
// GOOD: Well-structured types with clear relationships
type BaseWorker struct {
    ID        string
    StartedAt time.Time

    // Synchronization
    mu       sync.RWMutex
    stopped  bool
    stopChan chan struct{}

    // Statistics
    stats WorkerStats
}

type WorkerStats struct {
    TasksProcessed int64
    TasksSucceeded int64
    TasksFailed    int64
    LastActivity   time.Time
}

type RoleBasedWorker struct {
    BaseWorker  // Embedded for common functionality

    Role         WorkerRole
    Capabilities WorkerCapabilities
    Processor    TaskProcessor

    // Role-specific configuration
    Config *RoleConfig
}

func (w *RoleBasedWorker) UpdateStats(success bool) {
    w.mu.Lock()
    defer w.mu.Unlock()

    w.stats.TasksProcessed++
    if success {
        w.stats.TasksSucceeded++
    } else {
        w.stats.TasksFailed++
    }
    w.stats.LastActivity = time.Now()
}

func (w *RoleBasedWorker) GetStats() WorkerStats {
    w.mu.RLock()
    defer w.mu.RUnlock()

    return w.stats  // Copy of stats
}

// BAD: Flat structure without clear organization
type Worker struct {
    ID               string
    StartedAt        time.Time
    Role             WorkerRole
    Capabilities     WorkerCapabilities
    Processor        TaskProcessor
    Config           *RoleConfig
    TasksProcessed   int64
    TasksSucceeded   int64
    TasksFailed      int64
    LastActivity     time.Time
    Stopped          bool
    StopChan         chan struct{}
    Mutex            sync.RWMutex  // Should use mu for brevity
}
```

## Concurrency Patterns

### Goroutines and Channels

- Use channels for communication between goroutines
- Close channels at the sender side
- Use context for cancellation
- Avoid shared state when possible

```go
// GOOD: Proper channel usage with context
type MessageProcessor struct {
    workerCount int
    inputChan   chan Message
    resultChan  chan Result
    errorChan   chan error

    ctx    context.Context
    cancel context.CancelFunc
    wg     sync.WaitGroup
}

func NewMessageProcessor(workerCount int) *MessageProcessor {
    ctx, cancel := context.WithCancel(context.Background())

    return &MessageProcessor{
        workerCount: workerCount,
        inputChan:   make(chan Message, 100),  // Buffered for performance
        resultChan:  make(chan Result, 100),
        errorChan:   make(chan error, 10),
        ctx:         ctx,
        cancel:      cancel,
    }
}

func (mp *MessageProcessor) Start() {
    // Start worker goroutines
    for i := 0; i < mp.workerCount; i++ {
        mp.wg.Add(1)
        go mp.worker(i)
    }

    // Start result collector
    mp.wg.Add(1)
    go mp.resultCollector()
}

func (mp *MessageProcessor) worker(id int) {
    defer mp.wg.Done()

    for {
        select {
        case message, ok := <-mp.inputChan:
            if !ok {
                return  // Channel closed
            }

            result, err := mp.processMessage(message)
            if err != nil {
                select {
                case mp.errorChan <- fmt.Errorf("worker %d: %w", id, err):
                case <-mp.ctx.Done():
                    return
                }
                continue
            }

            select {
            case mp.resultChan <- result:
            case <-mp.ctx.Done():
                return
            }

        case <-mp.ctx.Done():
            return
        }
    }
}

func (mp *MessageProcessor) Stop() {
    mp.cancel()  // Signal cancellation
    close(mp.inputChan)  // Close input channel
    mp.wg.Wait()  // Wait for all workers to finish
    close(mp.resultChan)
    close(mp.errorChan)
}

// BAD: Poor concurrency management
func processMessages(messages []Message) {
    var wg sync.WaitGroup

    for _, msg := range messages {
        wg.Add(1)
        go func(m Message) {  // Variable capture issue
            defer wg.Done()
            processMessage(m)  // No error handling
        }(msg)
    }

    wg.Wait()
    // No way to cancel, no error collection
}
```

### Context Usage

- Pass context as the first parameter
- Use context for cancellation and deadlines
- Don't store context in structs (except for long-lived services)

```go
// GOOD: Proper context usage
func (s *Service) ProcessWithTimeout(ctx context.Context, data []byte, timeout time.Duration) error {
    // Create timeout context
    timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
    defer cancel()

    // Pass context down the call chain
    result, err := s.parseData(timeoutCtx, data)
    if err != nil {
        return fmt.Errorf("parsing failed: %w", err)
    }

    if err := s.validateResult(timeoutCtx, result); err != nil {
        return fmt.Errorf("validation failed: %w", err)
    }

    return s.storeResult(timeoutCtx, result)
}

func (s *Service) parseData(ctx context.Context, data []byte) (*ParsedData, error) {
    done := make(chan struct{})
    var result *ParsedData
    var err error

    go func() {
        defer close(done)
        result, err = s.heavyParsingOperation(data)
    }()

    select {
    case <-done:
        return result, err
    case <-ctx.Done():
        return nil, ctx.Err()
    }
}

// BAD: Not using context properly
func (s *Service) ProcessWithTimeout(data []byte, timeout time.Duration) error {
    // No context propagation
    time.AfterFunc(timeout, func() {
        // No clean way to cancel
    })

    result, err := s.parseData(data)  // No cancellation support
    if err != nil {
        return err
    }

    return s.storeResult(result)
}
```

## Testing Standards

### Table-Driven Tests

- Use table-driven tests for multiple scenarios
- Include both positive and negative test cases
- Use descriptive test names

```go
// GOOD: Comprehensive table-driven tests
func TestWorkflowOrchestrator_GetNextStage(t *testing.T) {
    tests := []struct {
        name         string
        currentStage types.WorkflowStage
        result       types.WorkflowResult
        workflow     *WorkflowState
        expectedNext types.WorkflowStage
        expectUpdate bool
    }{
        {
            name:         "development to review success",
            currentStage: types.StageDevelopment,
            result: types.WorkflowResult{
                TaskResult: types.TaskResult{Success: true, Result: "Code created"},
                Stage:      types.StageDevelopment,
            },
            workflow:     &WorkflowState{ReviewFeedback: ""},
            expectedNext: types.StageReview,
            expectUpdate: false,
        },
        {
            name:         "approval approved to testing",
            currentStage: types.StageApproval,
            result: types.WorkflowResult{
                TaskResult: types.TaskResult{
                    Success: true,
                    Result:  "APPROVED: Implementation looks good",
                },
                Stage: types.StageApproval,
            },
            workflow:     &WorkflowState{ReviewFeedback: ""},
            expectedNext: types.StageTesting,
            expectUpdate: false,
        },
        {
            name:         "approval rejected back to review",
            currentStage: types.StageApproval,
            result: types.WorkflowResult{
                TaskResult: types.TaskResult{
                    Success: true,
                    Result:  "REJECTED: Needs better error handling",
                },
                Stage: types.StageApproval,
            },
            workflow:     &WorkflowState{ReviewFeedback: ""},
            expectedNext: types.StageReview,
            expectUpdate: true,
        },
        {
            name:         "testing passed to completed",
            currentStage: types.StageTesting,
            result: types.WorkflowResult{
                TaskResult: types.TaskResult{
                    Success: true,
                    Result:  "PASSED: All tests successful",
                },
                Stage: types.StageTesting,
            },
            workflow:     &WorkflowState{ReviewFeedback: ""},
            expectedNext: types.StageCompleted,
            expectUpdate: false,
        },
    }

    orchestrator := NewWorkflowOrchestrator("localhost", 1883)

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            originalFeedback := tt.workflow.ReviewFeedback

            nextStage := orchestrator.getNextStage(tt.workflow, tt.result)

            if nextStage != tt.expectedNext {
                t.Errorf("getNextStage() = %v, want %v", nextStage, tt.expectedNext)
            }

            if tt.expectUpdate {
                if tt.workflow.ReviewFeedback == originalFeedback {
                    t.Errorf("Expected ReviewFeedback to be updated, but it remained: %s", originalFeedback)
                }
            } else {
                if tt.workflow.ReviewFeedback != originalFeedback {
                    t.Errorf("Expected ReviewFeedback to remain unchanged, but got: %s", tt.workflow.ReviewFeedback)
                }
            }
        })
    }
}

// BAD: Multiple individual test functions
func TestDevelopmentToReview(t *testing.T) {
    // Duplicate setup code
    orchestrator := NewWorkflowOrchestrator("localhost", 1883)
    workflow := &WorkflowState{}
    result := types.WorkflowResult{} // Test implementation
    // ...
}

func TestApprovalToTesting(t *testing.T) {
    // More duplicate setup code
    orchestrator := NewWorkflowOrchestrator("localhost", 1883)
    // ...
}
```

### Mock and Interface Testing

- Create interfaces for external dependencies
- Use dependency injection for testability
- Mock external services and network calls

```go
// GOOD: Testable design with mocks
type MockMQTTClient struct {
    connected      bool
    publishedMsgs  []MockMessage
    subscriptions  map[string]mqtt.MessageHandler
    connectError   error
    publishError   error
}

func (m *MockMQTTClient) Connect(ctx context.Context) error {
    if m.connectError != nil {
        return m.connectError
    }
    m.connected = true
    return nil
}

func (m *MockMQTTClient) Publish(ctx context.Context, topic string, payload []byte) error {
    if m.publishError != nil {
        return m.publishError
    }
    m.publishedMsgs = append(m.publishedMsgs, MockMessage{
        Topic:   topic,
        Payload: payload,
    })
    return nil
}

func TestWorkflowOrchestrator_ExecuteStage(t *testing.T) {
    mockClient := &MockMQTTClient{}
    orchestrator := NewWorkflowOrchestrator("localhost", 1883)
    orchestrator.mqttClient = mockClient  // Inject mock

    workflow := &WorkflowState{
        ID:      "test-workflow",
        Type:    "create_document",
        Stage:   types.StageDevelopment,
        Payload: map[string]string{"document_type": "coding_standards"},
    }

    orchestrator.executeStage(workflow, types.StageDevelopment)

    // Verify MQTT message was published
    if len(mockClient.publishedMsgs) != 1 {
        t.Errorf("Expected 1 published message, got %d", len(mockClient.publishedMsgs))
    }

    msg := mockClient.publishedMsgs[0]
    expectedTopic := "tasks/workflow/development"
    if msg.Topic != expectedTopic {
        t.Errorf("Expected topic %s, got %s", expectedTopic, msg.Topic)
    }
}

// BAD: Hard to test due to tight coupling
func TestOrchestrator(t *testing.T) {
    orchestrator := NewWorkflowOrchestrator("localhost", 1883)
    // Can't control MQTT behavior, test depends on external service
    err := orchestrator.Start()  // Requires real MQTT broker
    if err != nil {
        t.Skip("MQTT broker not available")  // Test becomes flaky
    }
}
```

## Code Organization

### Directory Structure

- Follow Go project layout conventions
- Separate internal and public packages
- Group related functionality together

```
.
├── cmd/                    # Application entry points
│   ├── orchestrator/       # Workflow orchestrator main
│   ├── role-worker/        # Role-based worker main
│   ├── client/            # CLI client main
│   └── rag-service/       # RAG service main
├── internal/              # Private application code
│   ├── mqtt/              # MQTT client implementation
│   ├── rag/               # RAG service implementation
│   ├── worker/            # Worker logic and processing
│   ├── orchestrator/      # Workflow orchestration logic
│   └── config/            # Configuration management
├── pkg/                   # Public library code
│   ├── types/             # Shared type definitions
│   └── userservice/       # User-level service interfaces
├── scripts/               # Build and deployment scripts
├── docs/                  # Documentation
└── testdata/              # Test fixtures and data
```

### File Organization

- One main type per file
- Group related functions with their types
- Use descriptive file names

```go
// GOOD: types.go - Core type definitions
package types

// Task represents a work item
type Task struct {
    ID        string            `json:"id"`
    Type      string            `json:"type"`
    Payload   map[string]string `json:"payload"`
    CreatedAt time.Time         `json:"created_at"`
    Priority  int               `json:"priority"`
}

// workflow.go - Workflow-specific types
package types

// WorkflowTask extends Task with workflow-specific fields
type WorkflowTask struct {
    Task                   // Embedded Task
    WorkflowID     string  `json:"workflow_id"`
    Stage          WorkflowStage `json:"stage"`
    RequiredRole   WorkerRole    `json:"required_role"`
    PreviousOutput string        `json:"previous_output"`
    ReviewFeedback string        `json:"review_feedback"`
}

// client.go - MQTT client implementation
package mqtt

type Client struct {
    // Client fields
}

func NewClient(host string, port int) *Client {
    // Constructor
}

func (c *Client) Connect(ctx context.Context) error {
    // Connection logic
}

// Additional Client methods follow...
```

## Performance Guidelines

### Memory Management

- Minimize allocations in hot paths
- Reuse slices and maps where possible
- Use sync.Pool for frequently allocated objects

```go
// GOOD: Efficient memory usage
type MessageProcessor struct {
    bufferPool sync.Pool
    workerPool sync.Pool
}

func NewMessageProcessor() *MessageProcessor {
    mp := &MessageProcessor{}

    mp.bufferPool = sync.Pool{
        New: func() interface{} {
            return make([]byte, 0, 1024)  // Pre-allocate capacity
        },
    }

    mp.workerPool = sync.Pool{
        New: func() interface{} {
            return &Worker{}
        },
    }

    return mp
}

func (mp *MessageProcessor) ProcessMessage(data []byte) (*Result, error) {
    // Get buffer from pool
    buffer := mp.bufferPool.Get().([]byte)
    defer mp.bufferPool.Put(buffer[:0])  // Reset length but keep capacity

    // Use buffer for processing
    buffer = append(buffer, data...)

    // Process and return result
    return mp.processBuffer(buffer)
}

func (mp *MessageProcessor) processLargeSlice(items []Item) error {
    const batchSize = 1000

    // Process in batches to avoid large memory spikes
    for i := 0; i < len(items); i += batchSize {
        end := i + batchSize
        if end > len(items) {
            end = len(items)
        }

        batch := items[i:end:end]  // Limit capacity to prevent memory leaks
        if err := mp.processBatch(batch); err != nil {
            return err
        }
    }

    return nil
}

// BAD: Inefficient memory usage
func ProcessMessage(data []byte) (*Result, error) {
    buffer := make([]byte, len(data)*2)  // Always allocate, often too much
    copy(buffer, data)

    // Multiple allocations in loop
    var results []Result
    for i := 0; i < 1000; i++ {
        result := &Result{}  // Allocation in loop
        results = append(results, *result)  // Multiple slice reallocations
    }

    return &results[0], nil
}
```

### String Operations

- Use strings.Builder for concatenation
- Avoid unnecessary string conversions
- Pre-allocate capacity when size is known

```go
// GOOD: Efficient string operations
func BuildLogMessage(level, component, message string, fields map[string]string) string {
    // Pre-calculate approximate size
    size := len(level) + len(component) + len(message) + 50  // Base format
    for k, v := range fields {
        size += len(k) + len(v) + 4  // key=value + separators
    }

    var builder strings.Builder
    builder.Grow(size)  // Pre-allocate capacity

    builder.WriteString("[")
    builder.WriteString(level)
    builder.WriteString("] ")
    builder.WriteString(component)
    builder.WriteString(": ")
    builder.WriteString(message)

    if len(fields) > 0 {
        builder.WriteString(" {")
        first := true
        for k, v := range fields {
            if !first {
                builder.WriteString(", ")
            }
            builder.WriteString(k)
            builder.WriteString("=")
            builder.WriteString(v)
            first = false
        }
        builder.WriteString("}")
    }

    return builder.String()
}

func ConvertBytesToString(data []byte) string {
    // Only convert when necessary
    if len(data) == 0 {
        return ""
    }

    // Use unsafe conversion for read-only scenarios (be careful!)
    return string(data)
}

// BAD: Inefficient string operations
func BuildLogMessage(level, component, message string, fields map[string]string) string {
    result := "[" + level + "] " + component + ": " + message  // Multiple allocations

    if len(fields) > 0 {
        result += " {"  // More allocations
        for k, v := range fields {
            result += k + "=" + v + ", "  // Allocation per iteration
        }
        result = result[:len(result)-2] + "}"  // String slicing creates new allocation
    }

    return result
}
```

## Documentation Standards

### Package Documentation

- Include package-level documentation
- Explain the package's purpose and main concepts
- Provide usage examples

```go
// GOOD: Comprehensive package documentation

// Package rag provides Retrieval-Augmented Generation (RAG) capabilities
// for the MQTT Agent Orchestration System.
//
// This package integrates with Qdrant vector database to store and retrieve
// contextual information for AI agents, enabling:
//   - System prompt management for different worker roles
//   - Knowledge base search for coding standards and patterns
//   - Context-aware task processing to reduce token usage
//
// Basic Usage:
//
//     service := rag.NewService("", "http://localhost:6333")
//     ctx := context.Background()
//
//     // Initialize collections
//     if err := service.InitializeCollections(ctx); err != nil {
//         log.Fatal(err)
//     }
//
//     // Store a system prompt
//     err := service.StoreSystemPrompt(ctx, types.RoleDeveloper,
//         "You are an expert Go developer...")
//
//     // Retrieve system prompt
//     prompt, err := service.GetSystemPrompt(ctx, types.RoleDeveloper)
//
// The service gracefully degrades when Qdrant is unavailable by falling
// back to hardcoded prompts and simple keyword matching.
package rag
```

### Function Documentation

- Document exported functions with godoc format
- Include parameter descriptions and return values
- Provide examples for complex functions

```go
// ProcessWorkflowTask processes a workflow task according to the worker's role.
// It retrieves the appropriate system prompt and contextual information from
// the RAG service to optimize AI API calls.
//
// The function:
//   1. Validates that the task matches the worker's role
//   2. Retrieves system prompt and RAG context
//   3. Delegates to role-specific processing methods
//   4. Returns the processed result or an error
//
// Parameters:
//   - ctx: Context for cancellation and timeout control
//   - workflowTask: The task to process, must have RequiredRole matching worker's role
//
// Returns:
//   - string: The processed result (content, review, approval decision, or test results)
//   - error: Any error that occurred during processing
//
// Example:
//
//     processor := NewRoleBasedProcessor(types.RoleDeveloper, ragService)
//     task := &types.WorkflowTask{
//         Task: types.Task{
//             ID:   "task-1",
//             Type: "create_document",
//             Payload: map[string]string{"document_type": "go_coding_standards"},
//         },
//         RequiredRole: types.RoleDeveloper,
//         WorkflowID:   "workflow-1",
//         Stage:        types.StageDevelopment,
//     }
//
//     result, err := processor.ProcessWorkflowTask(ctx, task)
//     if err != nil {
//         log.Printf("Processing failed: %v", err)
//         return
//     }
//     log.Printf("Task completed: %s", result)
func (p *RoleBasedProcessor) ProcessWorkflowTask(ctx context.Context, workflowTask *types.WorkflowTask) (string, error) {
    // Implementation...
}

// BAD: Poor or missing documentation
// ProcessWorkflowTask processes a task
func (p *RoleBasedProcessor) ProcessWorkflowTask(ctx context.Context, workflowTask *types.WorkflowTask) (string, error) {
    // No explanation of what it does, parameters, or return values
}
```

## Security Guidelines

### Input Validation

- Validate all inputs at service boundaries
- Sanitize data before processing
- Use whitelist validation when possible

```go
// GOOD: Comprehensive input validation
func (s *WorkflowService) CreateWorkflow(ctx context.Context, req *CreateWorkflowRequest) (*Workflow, error) {
    if req == nil {
        return nil, fmt.Errorf("request cannot be nil")
    }

    // Validate workflow type
    if err := validateWorkflowType(req.Type); err != nil {
        return nil, fmt.Errorf("invalid workflow type: %w", err)
    }

    // Validate payload
    if err := validatePayload(req.Payload); err != nil {
        return nil, fmt.Errorf("invalid payload: %w", err)
    }

    // Validate user permissions
    if err := s.authService.ValidatePermissions(ctx, req.UserID, "workflow:create"); err != nil {
        return nil, fmt.Errorf("permission denied: %w", err)
    }

    // Sanitize inputs
    sanitizedType := sanitizeWorkflowType(req.Type)
    sanitizedPayload := sanitizePayload(req.Payload)

    return s.createWorkflowInternal(ctx, sanitizedType, sanitizedPayload)
}

func validateWorkflowType(workflowType string) error {
    allowedTypes := map[string]bool{
        "create_document":     true,
        "code_review":         true,
        "security_audit":      true,
        "performance_review":  true,
    }

    if !allowedTypes[workflowType] {
        return fmt.Errorf("workflow type '%s' not allowed", workflowType)
    }

    return nil
}

func validatePayload(payload map[string]string) error {
    // Check for required fields
    requiredFields := []string{"document_type", "target_language"}
    for _, field := range requiredFields {
        if value, exists := payload[field]; !exists || value == "" {
            return fmt.Errorf("required field '%s' is missing or empty", field)
        }
    }

    // Validate specific field values
    if docType := payload["document_type"]; docType != "" {
        allowedDocTypes := []string{"coding_standards", "api_documentation", "user_guide"}
        if !contains(allowedDocTypes, docType) {
            return fmt.Errorf("document_type '%s' not allowed", docType)
        }
    }

    return nil
}

// BAD: No input validation
func (s *WorkflowService) CreateWorkflow(ctx context.Context, req *CreateWorkflowRequest) (*Workflow, error) {
    // Direct use without validation
    return s.createWorkflowInternal(ctx, req.Type, req.Payload)
}
```

### Secret Management

- Never log or expose secrets
- Use environment variables or secure vaults
- Rotate secrets regularly

```go
// GOOD: Secure secret handling
type Config struct {
    MQTTHost     string
    MQTTPort     int
    QdrantURL    string

    // Secrets (never logged)
    APIKey       string `json:"-"`  // JSON tag prevents logging
    DatabasePass string `json:"-"`
}

func LoadConfig() (*Config, error) {
    config := &Config{}

    // Load from environment variables
    config.APIKey = os.Getenv("API_KEY")
    if config.APIKey == "" {
        return nil, fmt.Errorf("API_KEY environment variable is required")
    }

    config.DatabasePass = os.Getenv("DATABASE_PASSWORD")
    if config.DatabasePass == "" {
        return nil, fmt.Errorf("DATABASE_PASSWORD environment variable is required")
    }

    // Load non-sensitive config from file
    if err := loadFromFile(config, "config.yaml"); err != nil {
        return nil, fmt.Errorf("failed to load config: %w", err)
    }

    return config, nil
}

func (c *Config) String() string {
    // Never include secrets in string representation
    return fmt.Sprintf("Config{MQTTHost: %s, MQTTPort: %d, QdrantURL: %s}",
        c.MQTTHost, c.MQTTPort, c.QdrantURL)
}

func (s *Service) authenticateRequest(ctx context.Context, apiKey string) error {
    // Use secure comparison to prevent timing attacks
    expectedKey := s.config.APIKey
    if len(apiKey) != len(expectedKey) {
        return fmt.Errorf("invalid API key")
    }

    if subtle.ConstantTimeCompare([]byte(apiKey), []byte(expectedKey)) != 1 {
        return fmt.Errorf("invalid API key")
    }

    return nil
}

// BAD: Insecure secret handling
type Config struct {
    MQTTHost     string
    MQTTPort     int
    QdrantURL    string
    APIKey       string  // Will be included in logs!
    DatabasePass string  // Will be included in logs!
}

func (s *Service) authenticateRequest(ctx context.Context, apiKey string) error {
    log.Printf("Checking API key: %s", apiKey)  // Logs secret!

    if apiKey == s.config.APIKey {  // Vulnerable to timing attacks
        return nil
    }

    return fmt.Errorf("invalid API key")
}
```

## Compliance Checklist

### Code Quality

- [ ] All functions have clear, descriptive names
- [ ] Variables are declared close to their usage
- [ ] Error handling is explicit and contextual
- [ ] Interfaces are small and focused
- [ ] Structs are well-organized with clear relationships

### Error Handling

- [ ] Every error is checked immediately after the operation
- [ ] Errors include sufficient context for debugging
- [ ] Error wrapping preserves the original error
- [ ] Custom error types are used for domain-specific errors
- [ ] No errors are ignored (use `_ = err` if intentional)

### Testing

- [ ] Unit tests cover all public functions
- [ ] Table-driven tests are used for multiple scenarios
- [ ] Mocks are used for external dependencies
- [ ] Tests include both positive and negative cases
- [ ] Test names clearly describe what is being tested

### Documentation

- [ ] Package documentation explains purpose and usage
- [ ] Exported functions have godoc comments
- [ ] Complex functions include usage examples
- [ ] Code comments explain "why" not "what"
- [ ] README.md is up-to-date and accurate

### Security

- [ ] All inputs are validated at service boundaries
- [ ] Secrets are never logged or exposed
- [ ] User permissions are checked before operations
- [ ] SQL injection and other injection attacks are prevented
- [ ] Timing attacks are mitigated in security-critical code

### Performance

- [ ] Memory allocations are minimized in hot paths
- [ ] String concatenation uses strings.Builder
- [ ] Large slices are processed in batches
- [ ] sync.Pool is used for frequently allocated objects
- [ ] Goroutine leaks are prevented with proper cleanup

### Concurrency

- [ ] Context is used for cancellation and timeouts
- [ ] Channels are closed by the sender
- [ ] Goroutines have proper cleanup mechanisms
- [ ] Race conditions are avoided or properly synchronized
- [ ] Deadlocks are prevented through consistent lock ordering

This standard serves as both a guide for writing new code and a checklist for reviewing existing code. Adherence to these standards ensures that Go code developed with Claude Code is maintainable, reliable, and robust.

