package tokenization

import (
	"context"
	"fmt"
	"strings"
	"sync"

	"k8s.io/client-go/util/workqueue"
)

// Task represents a unit of work for tokenizing a prompt.
type Task struct {
	Prompt    string
	ModelName string
}

// Pool encapsulates the queue, worker pool, and token indexer.
type Pool struct {
	workers int
	queue   workqueue.TypedRateLimitingInterface[Task]
	indexer TokenIndexer
	wg      sync.WaitGroup
}

// NewTokenizationPool initializes a TokenizationPool with the specified number
// of workers and the provided TokenIndexer.
func NewTokenizationPool(workers int, indexer TokenIndexer) *Pool {
	return &Pool{
		workers: workers,
		queue:   workqueue.NewTypedRateLimitingQueue(workqueue.DefaultTypedControllerRateLimiter[Task]()),
		indexer: indexer,
	}
}

// AddTask enqueues a new tokenization task.
func (pool *Pool) AddTask(prompt, modelName string) {
	task := Task{
		Prompt:    prompt,
		ModelName: modelName,
	}
	pool.queue.Add(task)
}

// Run launches worker goroutines that process tasks until the context is
// cancelled.
func (pool *Pool) Run(ctx context.Context) {
	for i := 0; i < pool.workers; i++ {
		pool.wg.Add(1)
		go pool.workerLoop(i)
	}
	// Wait for context cancellation.
	<-ctx.Done()

	// Shutdown the queue (which causes Get() to return shutdown=true).
	pool.queue.ShutDown()
	pool.wg.Wait()
}

// workerLoop is the main processing loop for each worker.
func (pool *Pool) workerLoop(workerID int) {
	defer pool.wg.Done()
	for {
		task, shutdown := pool.queue.Get()
		if shutdown {
			return
		}

		// Process the task.
		if err := pool.processTask(&task); err == nil {
			pool.queue.Forget(task)
		} else {
			// In case of error, requeue with rate limiting.
			pool.queue.AddRateLimited(task)
		}
		pool.queue.Done(task)
	}
}

// processTask tokenizes the prompt, extracts a prefix, and updates the
// indexer.
func (pool *Pool) processTask(task *Task) error {
	// For demonstration purposes, we split the prompt by whitespace.
	tokens := tokenize(task.Prompt)
	tokenCount := len(tokens)

	// Use the first token as the prefix. If no token exists, set prefix to empty.
	prefix := ""
	if tokenCount > 0 {
		prefix = tokens[0]
	}

	// Update the indexer with the computed token count for the prefix.
	pool.indexer.Update(prefix, tokenCount)

	// Print a message for demonstration.
	fmt.Printf("Worker processed task for model '%s': prefix='%s', tokens=%d\n", task.ModelName, prefix, tokenCount)
	return nil
}

// tokenize is a simple helper function to split a string into tokens.
func tokenize(s string) []string {
	return strings.Fields(s)
}
