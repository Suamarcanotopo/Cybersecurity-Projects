// ©AngelaMos | 2026
// aggregator_test.go

package coinbase_test

import (
	"testing"
	"time"

	"github.com/shopspring/decimal"
	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/coinbase"
)

func TestAggregator_FirstTickOpensBar(t *testing.T) {
	a := coinbase.NewAggregator()
	ts := time.Date(2026, 5, 1, 12, 0, 30, 0, time.UTC)
	closed, cur := a.Push(coinbase.Tick{
		Symbol: "BTC-USD", TS: ts,
		Price:     decimal.RequireFromString("42000"),
		Volume24h: decimal.RequireFromString("100"),
	})
	require.Nil(t, closed)
	require.Equal(t, ts.Truncate(time.Minute), cur.Minute)
	require.True(t, cur.Open.Equal(decimal.RequireFromString("42000")))
	require.True(t, cur.Close.Equal(decimal.RequireFromString("42000")))
}

func TestAggregator_FoldUpdatesHighLowClose(t *testing.T) {
	a := coinbase.NewAggregator()
	min := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)
	a.Push(
		coinbase.Tick{
			Symbol:    "BTC-USD",
			TS:        min.Add(10 * time.Second),
			Price:     decimal.RequireFromString("42000"),
			Volume24h: decimal.RequireFromString("100"),
		},
	)
	a.Push(
		coinbase.Tick{
			Symbol:    "BTC-USD",
			TS:        min.Add(20 * time.Second),
			Price:     decimal.RequireFromString("42050"),
			Volume24h: decimal.RequireFromString("110"),
		},
	)
	closed, cur := a.Push(coinbase.Tick{
		Symbol: "BTC-USD",
		TS:     min.Add(30 * time.Second),
		Price: decimal.RequireFromString(
			"41950",
		),
		Volume24h: decimal.RequireFromString("120"),
	})
	require.Nil(t, closed)
	require.True(t, cur.Open.Equal(decimal.RequireFromString("42000")))
	require.True(t, cur.High.Equal(decimal.RequireFromString("42050")))
	require.True(t, cur.Low.Equal(decimal.RequireFromString("41950")))
	require.True(t, cur.Close.Equal(decimal.RequireFromString("41950")))
	require.True(
		t,
		cur.Volume24hAtClose.Equal(decimal.RequireFromString("120")),
	)
}

func TestAggregator_MinuteRolloverEmitsClosedBar(t *testing.T) {
	a := coinbase.NewAggregator()
	min1 := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)
	min2 := min1.Add(time.Minute)

	a.Push(
		coinbase.Tick{
			Symbol:    "BTC-USD",
			TS:        min1.Add(10 * time.Second),
			Price:     decimal.RequireFromString("42000"),
			Volume24h: decimal.RequireFromString("100"),
		},
	)
	a.Push(
		coinbase.Tick{
			Symbol:    "BTC-USD",
			TS:        min1.Add(50 * time.Second),
			Price:     decimal.RequireFromString("42100"),
			Volume24h: decimal.RequireFromString("105"),
		},
	)

	closed, cur := a.Push(coinbase.Tick{
		Symbol: "BTC-USD",
		TS:     min2.Add(5 * time.Second),
		Price: decimal.RequireFromString(
			"42150",
		),
		Volume24h: decimal.RequireFromString("110"),
	})

	require.NotNil(t, closed)
	require.Equal(t, min1, closed.Minute)
	require.True(t, closed.Close.Equal(decimal.RequireFromString("42100")))

	require.Equal(t, min2, cur.Minute)
	require.True(t, cur.Open.Equal(decimal.RequireFromString("42150")))
}

func TestAggregator_BarsArePerProduct(t *testing.T) {
	a := coinbase.NewAggregator()
	min := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

	_, btc := a.Push(
		coinbase.Tick{
			Symbol:    "BTC-USD",
			TS:        min.Add(10 * time.Second),
			Price:     decimal.RequireFromString("42000"),
			Volume24h: decimal.RequireFromString("100"),
		},
	)
	_, eth := a.Push(
		coinbase.Tick{
			Symbol:    "ETH-USD",
			TS:        min.Add(11 * time.Second),
			Price:     decimal.RequireFromString("2300"),
			Volume24h: decimal.RequireFromString("80"),
		},
	)

	require.Equal(t, "BTC-USD", btc.Symbol)
	require.Equal(t, "ETH-USD", eth.Symbol)
	require.True(t, btc.Open.Equal(decimal.RequireFromString("42000")))
	require.True(t, eth.Open.Equal(decimal.RequireFromString("2300")))
}

func TestAggregator_FlushReturnsAllOpenBars(t *testing.T) {
	a := coinbase.NewAggregator()
	min := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)
	a.Push(
		coinbase.Tick{
			Symbol:    "BTC-USD",
			TS:        min.Add(10 * time.Second),
			Price:     decimal.RequireFromString("42000"),
			Volume24h: decimal.RequireFromString("100"),
		},
	)
	a.Push(
		coinbase.Tick{
			Symbol:    "ETH-USD",
			TS:        min.Add(15 * time.Second),
			Price:     decimal.RequireFromString("2300"),
			Volume24h: decimal.RequireFromString("80"),
		},
	)
	bars := a.Flush()
	require.Len(t, bars, 2)
}
