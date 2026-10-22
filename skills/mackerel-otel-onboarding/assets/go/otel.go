// otel.go: OpenTelemetry の初期化（このファイルをサービスの main パッケージにコピーする）
//
// 必要なモジュール:
//
//	go get go.opentelemetry.io/otel go.opentelemetry.io/otel/sdk go.opentelemetry.io/otel/sdk/metric go.opentelemetry.io/otel/sdk/log \
//	  go.opentelemetry.io/otel/log/global \
//	  go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp \
//	  go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp \
//	  go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp \
//	  go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp \
//	  go.opentelemetry.io/contrib/bridges/otelslog
//
// main() での使い方:
//
//	if shutdown, err := setupOTel(ctx); err != nil { slog.Warn("opentelemetry disabled", "err", err) } else { defer shutdown(context.Background()) }
//	logger := newLogger("my-service"); slog.SetDefault(logger)     // ログを stdout と OTel の両方へ
//	srv := &http.Server{Handler: instrumentHTTP(withLogging(mux))} // 計装ハンドラを最外側に（内側のログに trace_id が付く）
//	client := &http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)}
//
// ログを送らない場合は OTEL_LOGS_EXPORTER=none にする（LoggerProvider を作らない）。
// ハンドラ内では slog.InfoContext(r.Context(), ...) のように ctx 付きで記録すると trace_id / span_id が付く。
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strings"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// setupOTel はトレースとメトリクスの送信を初期化する。
// 送信先やサービス名は標準の環境変数（OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME,
// OTEL_RESOURCE_ATTRIBUTES, OTEL_METRIC_EXPORT_INTERVAL）から読む。
// 戻り値の関数を終了時に呼ぶと未送信のデータをフラッシュする。
func setupOTel(ctx context.Context) (func(context.Context) error, error) {
	// SDK 内部のエラー（送信失敗など）は stdout だけに出す。既定ロガー経由にすると
	// slog → OTel ログ → 送信失敗 → エラー → slog ... のループになるため
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		slog.New(slog.NewJSONHandler(os.Stdout, nil)).Warn("opentelemetry sdk error", "err", err)
	}))

	res, err := resource.New(ctx,
		resource.WithFromEnv(),
		resource.WithTelemetrySDK(),
		resource.WithProcessRuntimeDescription(),
	)
	if err != nil {
		return nil, err
	}

	traceExporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}
	tracerProvider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tracerProvider)

	metricExporter, err := otlpmetrichttp.New(ctx)
	if err != nil {
		_ = tracerProvider.Shutdown(ctx)
		return nil, err
	}
	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter)),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(meterProvider)

	// ログ: OTEL_LOGS_EXPORTER=none のときは送らない（SDK は環境変数を見ないので自前で判定）
	var loggerProvider *sdklog.LoggerProvider
	if os.Getenv("OTEL_LOGS_EXPORTER") != "none" {
		logExporter, err := otlploghttp.New(ctx)
		if err != nil {
			_ = tracerProvider.Shutdown(ctx)
			_ = meterProvider.Shutdown(ctx)
			return nil, err
		}
		loggerProvider = sdklog.NewLoggerProvider(
			sdklog.WithProcessor(sdklog.NewBatchProcessor(logExporter)),
			sdklog.WithResource(res),
		)
		global.SetLoggerProvider(loggerProvider)
	}

	// W3C Trace Context でサービス間にトレースをつなぐ
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	return func(ctx context.Context) error {
		errs := []error{tracerProvider.Shutdown(ctx), meterProvider.Shutdown(ctx)}
		if loggerProvider != nil {
			errs = append(errs, loggerProvider.Shutdown(ctx))
		}
		return errors.Join(errs...)
	}, nil
}

// newLogger は stdout（JSON）と OpenTelemetry の両方にログを出す slog.Logger を返す。
// OTel 側にはそのときのスパンの trace_id / span_id が自動で付くので、Mackerel でトレースからログを辿れる。
// setupOTel の後に呼ぶこと（前に呼ぶと OTel 側は noop になる）。
func newLogger(name string) *slog.Logger {
	return slog.New(fanoutHandler{
		slog.NewJSONHandler(os.Stdout, nil),
		otelslog.NewHandler(name),
	})
}

// fanoutHandler は複数の slog.Handler に同じレコードを渡す
type fanoutHandler []slog.Handler

func (h fanoutHandler) Enabled(ctx context.Context, l slog.Level) bool {
	for _, x := range h {
		if x.Enabled(ctx, l) {
			return true
		}
	}
	return false
}

func (h fanoutHandler) Handle(ctx context.Context, r slog.Record) error {
	var errs []error
	for _, x := range h {
		if x.Enabled(ctx, r.Level) {
			errs = append(errs, x.Handle(ctx, r.Clone()))
		}
	}
	return errors.Join(errs...)
}

func (h fanoutHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	out := make(fanoutHandler, len(h))
	for i, x := range h {
		out[i] = x.WithAttrs(attrs)
	}
	return out
}

func (h fanoutHandler) WithGroup(name string) slog.Handler {
	out := make(fanoutHandler, len(h))
	for i, x := range h {
		out[i] = x.WithGroup(name)
	}
	return out
}

// instrumentHTTP はサーバー全体を 1 つの otelhttp ハンドラで包む。
// Go 1.22+ の ServeMux ではルーティング後に r.Pattern が入るため、
// スパン名（例: "GET /products/{id}"）とメトリクスの http.route は自動で付く。
// ヘルスチェックは計装しない。対象パスは環境変数 OTEL_HTTP_EXCLUDE_PATHS（カンマ区切り）で変えられる。
func instrumentHTTP(h http.Handler) http.Handler {
	excluded := excludedPaths()
	return otelhttp.NewHandler(withRouteAttribute(h), "http.server",
		otelhttp.WithFilter(func(r *http.Request) bool {
			_, skip := excluded[r.URL.Path]
			return !skip
		}),
	)
}

// excludedPaths は計装しないパスの集合。既定は /healthz, /health, /readyz。
func excludedPaths() map[string]struct{} {
	list := "/healthz,/health,/readyz"
	if v := strings.TrimSpace(os.Getenv("OTEL_HTTP_EXCLUDE_PATHS")); v != "" {
		list = v
	}
	out := map[string]struct{}{}
	for _, p := range strings.Split(list, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out[p] = struct{}{}
		}
	}
	return out
}

// withRouteAttribute はルーティング後に確定する r.Pattern から http.route 属性をサーバースパンに付ける。
// otelhttp はメトリクスとスパン名には Pattern を使うが、スパン属性 http.route は付けないため、
// これがないと Mackerel APM のルート別集計が実パス（/products/123）ごとに分かれてしまう。
// chi / gin / echo などを使う場合は各フレームワークの otel ミドルウェアが http.route を付けるので不要。
func withRouteAttribute(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r)
		if r.Pattern == "" {
			return
		}
		route := r.Pattern
		if _, after, found := strings.Cut(r.Pattern, " "); found {
			route = after
		}
		trace.SpanFromContext(r.Context()).SetAttributes(attribute.String("http.route", route))
	})
}
