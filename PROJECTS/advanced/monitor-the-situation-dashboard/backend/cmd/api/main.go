// ©AngelaMos | 2026
// main.go

package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"golang.org/x/sync/errgroup"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/admin"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/alerts"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/auth"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/bus"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cfradar"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/coinbase"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/cve"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/dshield"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/gdelt"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/heartbeat"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/iss"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/kev"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/ransomware"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/state"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/swpc"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/usgs"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/wikipedia"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/config"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/core"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/enrich/abuseipdb"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/enrich/greynoise"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/health"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/intel"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/middleware"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/notifications"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/redisring"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/server"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/snapshot"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/user"
	"github.com/carterperez-dev/monitor-the-situation/backend/internal/ws"
)

const (
	drainDelay = 5 * time.Second
)

type abuseipdbEnricher struct {
	client *abuseipdb.Client
}

func (a abuseipdbEnricher) Lookup(
	ctx context.Context,
	ip string,
) (cfradar.Enrichment, error) {
	v, err := a.client.Lookup(ctx, ip)
	if err != nil {
		return cfradar.Enrichment{}, err
	}
	return cfradar.Enrichment{
		Country:         v.CountryCode,
		AbuseConfidence: v.AbuseConfidenceScore,
		ISP:             v.ISP,
	}, nil
}

type compositeDshieldEnricher struct {
	abuse *abuseipdb.Client
	gn    *greynoise.Cached
}

func (c compositeDshieldEnricher) Lookup(
	ctx context.Context,
	ip string,
) (dshield.DShieldEnrichment, error) {
	out := dshield.DShieldEnrichment{}
	if c.abuse != nil {
		if v, err := c.abuse.Lookup(ctx, ip); err == nil {
			out.Country = v.CountryCode
		}
	}
	if c.gn != nil {
		if v, err := c.gn.Lookup(ctx, ip); err == nil {
			out.Classification = v.Classification
			out.Actor = v.Name
		}
	}
	return out, nil
}

func main() {
	configPath := flag.String("config", "config.yaml", "path to config file")
	healthcheck := flag.Bool(
		"healthcheck",
		false,
		"probe local /healthz and exit 0 if healthy, 1 otherwise",
	)
	flag.Parse()

	if *healthcheck {
		os.Exit(runHealthcheck())
	}

	if err := run(*configPath); err != nil {
		slog.Error("application error", "error", err)
		os.Exit(1)
	}
}

func runHealthcheck() int {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:8080/healthz")
	if err != nil {
		return 1
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

//nolint:funlen // bootstrap code is inherently verbose
func run(configPath string) error {
	ctx, stop := signal.NotifyContext(
		context.Background(),
		syscall.SIGINT,
		syscall.SIGTERM,
	)
	defer stop()

	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}

	logger := setupLogger(cfg.Log)
	slog.SetDefault(logger)

	logger.Info("starting application",
		"name", cfg.App.Name,
		"version", cfg.App.Version,
		"environment", cfg.App.Environment,
	)

	var telemetry *core.Telemetry
	if cfg.Otel.Enabled {
		tel, telErr := core.NewTelemetry(ctx, cfg.Otel, cfg.App)
		if telErr != nil {
			logger.Warn("failed to initialize telemetry", "error", telErr)
		} else {
			telemetry = tel
			logger.Info("OpenTelemetry tracer initialized",
				"endpoint", cfg.Otel.Endpoint,
			)
		}
	}

	db, err := core.NewDatabase(ctx, cfg.Database)
	if err != nil {
		return err
	}
	logger.Info("database connected",
		"max_open_conns", cfg.Database.MaxOpenConns,
		"max_idle_conns", cfg.Database.MaxIdleConns,
	)

	redis, err := core.NewRedis(ctx, cfg.Redis)
	if err != nil {
		return err
	}
	logger.Info("redis connected",
		"pool_size", cfg.Redis.PoolSize,
	)

	if keyErr := ensureJWTKeys(cfg.JWT, logger); keyErr != nil {
		return keyErr
	}

	jwtManager, err := auth.NewJWTManager(cfg.JWT)
	if err != nil {
		return err
	}
	logger.Info("JWT manager initialized",
		"algorithm", "ES256",
		"key_id", jwtManager.GetKeyID(),
	)

	userRepo := user.NewRepository(db.DB)
	userSvc := user.NewService(userRepo)
	userHandler := user.NewHandler(userSvc)

	authRepo := auth.NewRepository(db.DB)
	authSvc := auth.NewServiceWithConfig(auth.ServiceConfig{
		Repo:         authRepo,
		JWT:          jwtManager,
		UserProvider: userSvc,
		Redis:        redis.Client,
		AdminEmail:   cfg.App.AdminEmail,
	})
	authVerifier := auth.NewVerifier(jwtManager, authSvc, userSvc)
	authHandler := auth.NewHandlerWithConfig(auth.HandlerConfig{
		Service:          authSvc,
		TrustedProxyHops: cfg.Server.TrustedProxyHops,
		SecureCookies:    cfg.IsProduction(),
	})

	var notifHandler *notifications.Handler
	var notifBridge *notifications.Bridge
	if cfg.Notifications.EncryptionKey != "" {
		enc, encErr := notifications.NewEncryptor(
			cfg.Notifications.EncryptionKey,
		)
		if encErr != nil {
			logger.Warn(
				"notifications disabled: invalid encryption key",
				"error", encErr,
			)
		} else {
			notifRepo := notifications.NewRepository(db.DB)
			notifSender := notifications.NewSender()
			notifSvc := notifications.NewService(
				notifRepo,
				enc,
				notifSender,
				cfg.App.PublicURL,
				logger.With("service", "notifications"),
			)
			notifHandler = notifications.NewHandler(notifSvc)
			notifBridge = notifications.NewBridge(
				notifRepo,
				enc,
				notifSender,
				logger.With("service", "alerts"),
			)
		}
	} else {
		logger.Warn(
			"notifications disabled: NOTIFICATION_ENCRYPTION_KEY not set",
		)
	}

	alertsRepo := alerts.NewRepository(db.DB)
	authSvc.SetRuleSeeder(func(ctx context.Context, userID string) error {
		return alertsRepo.SeedDefaults(ctx, userID)
	})
	alertsHandler := alerts.NewHandler(alertsRepo)

	healthHandler := health.NewHandler(db, redis)

	adminHandler := admin.NewHandler(admin.HandlerConfig{
		DBStats:    db.Stats,
		RedisStats: redis.PoolStats,
		DBPing:     db.Ping,
		RedisPing:  redis.Ping,
	})

	snapStore := snapshot.NewStore(redis.Client)
	snapHandler := snapshot.NewHandler(snapStore)

	cveRepo := cve.NewRepo(db.DB)
	kevRepo := kev.NewRepo(db.DB)
	cfradarRepo := cfradar.NewRepo(db.DB)
	ransomwareRepo := ransomware.NewRepo(db.DB)
	usgsRepo := usgs.NewRepo(db.DB)
	intelHandler := intel.NewHandler(intel.HandlerConfig{
		CVE:        cveRepo,
		KEV:        kevRepo,
		CFRadar:    cfradarRepo,
		Ransomware: ransomwareRepo,
		USGS:       usgsRepo,
	})

	hub := ws.NewHub(ws.HubConfig{
		Logger:         logger,
		MaxSubscribers: cfg.Server.WSMaxSubscribers,
	})
	wsHandler := ws.NewHandlerWithConfig(ws.HandlerConfig{
		Hub:              hub,
		MaxConnsPerIP:    cfg.Server.WSMaxConnsPerIP,
		TrustedProxyHops: cfg.Server.TrustedProxyHops,
	})

	eventBus := bus.New(bus.Config{
		BufferSize:  512,
		Persister:   snapshot.StorePersister{Store: snapStore},
		Broadcaster: ws.HubBroadcaster{Hub: hub},
		Logger:      logger,
	})

	beat := heartbeat.New(heartbeat.Config{
		Interval: 5 * time.Second,
		Emitter:  eventBus,
	})

	collectorState := state.NewRepo(db.DB)

	collectorGroup, collectorCtx := errgroup.WithContext(ctx)
	collectorGroup.Go(func() error { return eventBus.Run(collectorCtx) })
	collectorGroup.Go(func() error { return beat.Run(collectorCtx) })

	if notifBridge != nil {
		alertsEngine, err := alerts.NewEngine(alerts.EngineConfig{
			Repo:      alertsRepo,
			Notifier:  notifBridge,
			Loader:    notifBridge,
			Cooldowns: alerts.NewRedisCooldown(redis.Client),
			Logger:    logger.With("component", "alerts.engine"),
		})
		if err != nil {
			return err
		}
		dispatcher := alerts.NewDispatcher(
			eventBus.Subscribe(),
			alertsEngine,
			logger.With("component", "alerts.dispatcher"),
		)
		collectorGroup.Go(
			func() error { return alertsEngine.RefreshLoop(collectorCtx) },
		)
		collectorGroup.Go(func() error { return dispatcher.Run(collectorCtx) })
	} else {
		logger.Info(
			"alerts engine disabled (notifications module not configured)",
		)
	}

	if cfg.Collectors.DShield.Enabled {
		var dsEnricher dshield.Enricher
		var abuseClient *abuseipdb.Client
		var gnCached *greynoise.Cached
		if cfg.Collectors.AbuseIPDB.Enabled &&
			cfg.Collectors.AbuseIPDB.APIKey != "" {
			abuseClient = abuseipdb.NewClient(
				abuseipdb.ClientConfig{APIKey: cfg.Collectors.AbuseIPDB.APIKey},
			)
		}
		if cfg.Collectors.GreyNoise.Enabled &&
			cfg.Collectors.GreyNoise.APIKey != "" {
			gnCached = greynoise.NewCached(
				greynoise.NewClient(
					greynoise.ClientConfig{
						APIKey: cfg.Collectors.GreyNoise.APIKey,
					},
				),
				redis.Client,
			)
		}
		if abuseClient != nil || gnCached != nil {
			dsEnricher = compositeDshieldEnricher{
				abuse: abuseClient,
				gn:    gnCached,
			}
		}
		coll := dshield.NewCollector(dshield.CollectorConfig{
			Interval:  cfg.Collectors.DShield.Interval,
			Fetcher:   dshield.NewClient(dshield.ClientConfig{}),
			Persister: dshield.NewRepo(db.DB),
			Emitter:   eventBus,
			State:     collectorState,
			Enricher:  dsEnricher,
			Logger:    logger.With("collector", "dshield"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.CFRadar.Enabled {
		var enricher cfradar.Enricher
		if cfg.Collectors.AbuseIPDB.Enabled &&
			cfg.Collectors.AbuseIPDB.APIKey != "" {
			enricher = abuseipdbEnricher{
				client: abuseipdb.NewClient(
					abuseipdb.ClientConfig{
						APIKey: cfg.Collectors.AbuseIPDB.APIKey,
					},
				),
			}
		}
		coll := cfradar.NewCollector(cfradar.CollectorConfig{
			Interval:      cfg.Collectors.CFRadar.Interval,
			MinConfidence: cfg.Collectors.CFRadar.MinConfidence,
			Fetcher: cfradar.NewClient(
				cfradar.ClientConfig{
					BearerToken: cfg.Collectors.CFRadar.BearerToken,
				},
			),
			Repo:     cfradar.NewRepo(db.DB),
			Emitter:  eventBus,
			State:    collectorState,
			Enricher: enricher,
			Logger:   logger.With("collector", "cfradar"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.CVE.Enabled {
		coll := cve.NewCollector(cve.CollectorConfig{
			Interval: cfg.Collectors.CVE.Interval,
			Window:   cfg.Collectors.CVE.Window,
			NVD: cve.NewNVDClient(
				cve.NVDClientConfig{APIKey: cfg.Collectors.CVE.NVDAPIKey},
			),
			EPSS:    cve.NewEPSSClient(cve.EPSSClientConfig{}),
			Repo:    cve.NewRepo(db.DB),
			Emitter: eventBus,
			State:   collectorState,
			Logger:  logger.With("collector", "cve"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.KEV.Enabled {
		coll := kev.NewCollector(kev.CollectorConfig{
			Interval: cfg.Collectors.KEV.Interval,
			Fetcher:  kev.NewClient(kev.ClientConfig{}),
			Repo:     kev.NewRepo(db.DB),
			Emitter:  eventBus,
			State:    collectorState,
			Logger:   logger.With("collector", "kev"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.Ransomware.Enabled {
		coll := ransomware.NewCollector(ransomware.CollectorConfig{
			Interval: cfg.Collectors.Ransomware.Interval,
			Fetcher:  ransomware.NewClient(ransomware.ClientConfig{}),
			Repo:     ransomware.NewRepo(db.DB),
			Emitter:  eventBus,
			State:    collectorState,
			Logger:   logger.With("collector", "ransomware"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.Coinbase.Enabled {
		coll := coinbase.NewCollector(coinbase.CollectorConfig{
			URL:        cfg.Collectors.Coinbase.URL,
			ProductIDs: cfg.Collectors.Coinbase.ProductIDs,
			Repo:       coinbase.NewRepo(db.DB),
			Emitter:    eventBus,
			State:      collectorState,
			Throttle:   cfg.Collectors.Coinbase.Throttle,
			Logger:     logger.With("collector", "coinbase"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.USGS.Enabled {
		coll := usgs.NewCollector(usgs.CollectorConfig{
			Interval: cfg.Collectors.USGS.Interval,
			Fetcher:  usgs.NewClient(usgs.ClientConfig{}),
			Repo:     usgs.NewRepo(db.DB),
			Emitter:  eventBus,
			State:    collectorState,
			Logger:   logger.With("collector", "usgs"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.SWPC.Enabled {
		ring := redisring.New(
			redis.Client,
			redisring.Config{Retention: 24 * time.Hour},
		)
		coll := swpc.NewCollector(swpc.CollectorConfig{
			FastInterval: cfg.Collectors.SWPC.FastInterval,
			SlowInterval: cfg.Collectors.SWPC.SlowInterval,
			Fetcher:      swpc.NewClient(swpc.ClientConfig{}),
			Ring:         ring,
			Emitter:      eventBus,
			State:        collectorState,
			Logger:       logger.With("collector", "swpc"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.Wikipedia.Enabled {
		coll := wikipedia.NewCollector(wikipedia.CollectorConfig{
			Interval: cfg.Collectors.Wikipedia.Interval,
			Fetcher:  wikipedia.NewClient(wikipedia.ClientConfig{}),
			Repo:     wikipedia.NewRepo(db.DB, redis.Client),
			Emitter:  eventBus,
			State:    collectorState,
			Logger:   logger.With("collector", "wikipedia"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.GDELT.Enabled {
		coll := gdelt.NewCollector(gdelt.CollectorConfig{
			Interval: cfg.Collectors.GDELT.Interval,
			Fetcher:  gdelt.NewClient(gdelt.ClientConfig{}),
			Repo:     gdelt.NewRepo(db.DB),
			Emitter:  eventBus,
			State:    collectorState,
			Logger:   logger.With("collector", "gdelt"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	if cfg.Collectors.ISS.Enabled {
		coll := iss.NewCollector(iss.CollectorConfig{
			PositionInterval: cfg.Collectors.ISS.PositionInterval,
			TLEInterval:      cfg.Collectors.ISS.TLEInterval,
			Fetcher:          iss.NewClient(iss.ClientConfig{}),
			TLEStore:         iss.NewTLEStore(redis.Client),
			Emitter:          eventBus,
			State:            collectorState,
			Logger:           logger.With("collector", "iss"),
		})
		collectorGroup.Go(func() error { return coll.Run(collectorCtx) })
	}

	logger.Info("collectors started",
		"heartbeat", true,
		"dshield", cfg.Collectors.DShield.Enabled,
		"cfradar", cfg.Collectors.CFRadar.Enabled,
		"cve", cfg.Collectors.CVE.Enabled,
		"kev", cfg.Collectors.KEV.Enabled,
		"ransomware", cfg.Collectors.Ransomware.Enabled,
		"coinbase", cfg.Collectors.Coinbase.Enabled,
		"usgs", cfg.Collectors.USGS.Enabled,
		"swpc", cfg.Collectors.SWPC.Enabled,
		"wikipedia", cfg.Collectors.Wikipedia.Enabled,
		"gdelt", cfg.Collectors.GDELT.Enabled,
		"iss", cfg.Collectors.ISS.Enabled,
	)

	srv := server.New(server.Config{
		ServerConfig:  cfg.Server,
		HealthHandler: healthHandler,
		Logger:        logger,
	})

	router := srv.Router()

	router.Use(middleware.RequestID)
	router.Use(middleware.Logger(logger))
	router.Use(
		middleware.NewRateLimiter(redis.Client, middleware.RateLimitConfig{
			Limit: middleware.PerWindow(
				cfg.RateLimit.Requests,
				cfg.RateLimit.Burst,
				cfg.RateLimit.Window,
			),
			KeyFunc:  middleware.KeyByClientIP(cfg.Server.TrustedProxyHops),
			FailOpen: true,
		}).Handler,
	)
	router.Use(middleware.SecurityHeaders(cfg.App.Environment == "production"))
	router.Use(middleware.CORS(cfg.CORS))

	healthHandler.RegisterRoutes(router)

	router.Get("/.well-known/jwks.json", jwtManager.GetJWKSHandler())

	authenticator := middleware.Authenticator(authVerifier)
	adminOnly := middleware.RequireAdmin

	router.Route("/v1", func(r chi.Router) {
		r.Get("/healthz", healthHandler.Liveness)
		r.Get("/readyz", healthHandler.Readiness)

		r.Get("/snapshot", snapHandler.ServeHTTP)
		r.Get("/ws", wsHandler.ServeHTTP)

		intelHandler.RegisterRoutes(r)

		authHandler.RegisterRoutes(r, authenticator)

		userHandler.RegisterRoutes(r, authenticator)
		userHandler.RegisterAdminRoutes(r, authenticator, adminOnly)
		adminHandler.RegisterRoutes(r, authenticator, adminOnly)

		if notifHandler != nil {
			notifHandler.RegisterRoutes(r, authenticator)
		}
		if alertsHandler != nil {
			alertsHandler.RegisterRoutes(r, authenticator)
		}
	})

	errChan := make(chan error, 1)
	go func() {
		errChan <- srv.Start()
	}()

	select {
	case err := <-errChan:
		return err
	case <-ctx.Done():
		logger.Info("shutdown signal received")
	}

	shutdownCtx, cancel := context.WithTimeout(
		context.Background(),
		cfg.Server.ShutdownTimeout+drainDelay+5*time.Second,
	)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx, drainDelay); err != nil {
		logger.Error("server shutdown error", "error", err)
	}

	if telemetry != nil {
		if err := telemetry.Shutdown(shutdownCtx); err != nil {
			logger.Error("telemetry shutdown error", "error", err)
		}
	}

	if err := collectorGroup.Wait(); err != nil &&
		!errors.Is(err, context.Canceled) &&
		!errors.Is(err, context.DeadlineExceeded) {
		logger.Error("collector group exit", "error", err)
	}

	if err := redis.Close(); err != nil {
		logger.Error("redis close error", "error", err)
	}

	if err := db.Close(); err != nil {
		logger.Error("database close error", "error", err)
	}

	logger.Info("application stopped")
	return nil
}

func ensureJWTKeys(cfg config.JWTConfig, logger *slog.Logger) error {
	if _, err := os.Stat(cfg.PrivateKeyPath); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	if dir := filepath.Dir(cfg.PrivateKeyPath); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}
	if dir := filepath.Dir(cfg.PublicKeyPath); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}

	logger.Warn("JWT keys missing, generating",
		"private", cfg.PrivateKeyPath,
		"public", cfg.PublicKeyPath,
	)
	return auth.GenerateKeyPair(cfg.PrivateKeyPath, cfg.PublicKeyPath)
}

func setupLogger(cfg config.LogConfig) *slog.Logger {
	var handler slog.Handler

	level := slog.LevelInfo
	switch cfg.Level {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}

	opts := &slog.HandlerOptions{Level: level}

	if cfg.Format == "json" {
		handler = slog.NewJSONHandler(os.Stdout, opts)
	} else {
		handler = slog.NewTextHandler(os.Stdout, opts)
	}

	return slog.New(handler)
}
