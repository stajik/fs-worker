package main

import (
	"log"
	"os"

	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"

	"github.com/filesystem/fs-worker/activities"
)

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	temporalHost := envOrDefault("TEMPORAL_HOST", "localhost:7233")
	temporalNamespace := envOrDefault("TEMPORAL_NAMESPACE", "default")
	taskQueue := envOrDefault("TEMPORAL_TASK_QUEUE", "fs-worker")
	zfsPool := envOrDefault("ZFS_POOL", "testpool")

	log.Printf("Starting fs-worker Temporal activity worker")
	log.Printf("  TEMPORAL_HOST      = %s", temporalHost)
	log.Printf("  TEMPORAL_NAMESPACE = %s", temporalNamespace)
	log.Printf("  TEMPORAL_TASK_QUEUE= %s", taskQueue)
	log.Printf("  ZFS_POOL           = %s", zfsPool)

	c, err := client.Dial(client.Options{
		HostPort:  temporalHost,
		Namespace: temporalNamespace,
	})
	if err != nil {
		log.Fatalf("failed to create Temporal client: %v", err)
	}
	defer c.Close()

	w := worker.New(c, taskQueue, worker.Options{})

	acts := activities.NewFsWorkerActivities(zfsPool)
	w.RegisterActivity(acts)

	log.Printf("Worker registered on task queue %q — waiting for activity tasks", taskQueue)

	if err := w.Run(worker.InterruptCh()); err != nil {
		log.Fatalf("worker exited with error: %v", err)
	}
}
