package main

import (
	"log"
	"net/http"
	"os"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	tally "github.com/uber-go/tally/v4"
	tallyprom "github.com/uber-go/tally/v4/prometheus"
	"go.temporal.io/sdk/client"
	sdktally "go.temporal.io/sdk/contrib/tally"
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
	metricsAddr := envOrDefault("METRICS_ADDR", ":9090")

	log.Printf("Starting fs-worker Temporal activity worker")
	log.Printf("  TEMPORAL_HOST      = %s", temporalHost)
	log.Printf("  TEMPORAL_NAMESPACE = %s", temporalNamespace)
	log.Printf("  TEMPORAL_TASK_QUEUE= %s", taskQueue)
	log.Printf("  ZFS_POOL           = %s", zfsPool)
	log.Printf("  METRICS_ADDR       = %s", metricsAddr)

	// Set up Prometheus metrics reporter.
	tallyReporter := tallyprom.NewReporter(tallyprom.Options{
		DefaultTimerType: tallyprom.HistogramTimerType,
	})
	tallyScope, scopeCloser := tally.NewRootScope(tally.ScopeOptions{
		Prefix:         "temporal",
		CachedReporter: tallyReporter,
	}, 0)
	defer scopeCloser.Close()

	metricsHandler := sdktally.NewMetricsHandler(tallyScope)

	// Serve Prometheus /metrics endpoint.
	go func() {
		http.Handle("/metrics", promhttp.Handler())
		log.Printf("Prometheus metrics listening on %s/metrics", metricsAddr)
		if err := http.ListenAndServe(metricsAddr, nil); err != nil {
			log.Fatalf("metrics server failed: %v", err)
		}
	}()

	c, err := client.Dial(client.Options{
		HostPort:       temporalHost,
		Namespace:      temporalNamespace,
		MetricsHandler: metricsHandler,
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
