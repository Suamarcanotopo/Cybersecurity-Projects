// ©AngelaMos | 2026
// parser_test.go

package wikipedia_test

import (
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carterperez-dev/monitor-the-situation/backend/internal/collectors/wikipedia"
)

func TestParser_ExtractsITNEntriesFromFixture(t *testing.T) {
	body, err := os.ReadFile("testdata/itn_response.json")
	require.NoError(t, err)

	resp, err := wikipedia.DecodeResponse(body)
	require.NoError(t, err)
	require.NotZero(t, resp.RevID)

	entries := wikipedia.ParseEntries(resp.HTML)
	require.GreaterOrEqual(t, len(entries), 1)
	for _, e := range entries {
		require.NotEmpty(t, e.Text)
	}
	hasLink := false
	for _, e := range entries {
		if e.ArticleSlug != "" {
			hasLink = true
			break
		}
	}
	require.True(t, hasLink, "at least one entry should carry an article slug")
}

func TestParser_HandlesEmptyHTML(t *testing.T) {
	entries := wikipedia.ParseEntries("")
	require.Empty(t, entries)
}

func TestParser_StripsHTMLTagsFromText(t *testing.T) {
	entries := wikipedia.ParseEntries(
		`<ul><li>A reasonably long ITN-style sentence with <b>bold</b> and an inline <a href="/wiki/Topic">linked phrase</a> for context.</li></ul>`,
	)
	require.Len(t, entries, 1)
	require.Contains(t, entries[0].Text, "linked phrase")
	require.NotContains(t, entries[0].Text, "<b>")
	require.Equal(t, "Topic", entries[0].ArticleSlug)
}

func TestParser_SkipsListItemsWithoutLinks(t *testing.T) {
	entries := wikipedia.ParseEntries(
		`<ul><li>A long enough sentence with an actual linked <a href="/wiki/Foo">article reference</a> embedded.</li><li>Another long sentence that contains no link element at all in the body text.</li></ul>`,
	)
	require.Len(
		t,
		entries,
		1,
		"items without an article slug should be filtered out",
	)
	require.Equal(t, "Foo", entries[0].ArticleSlug)
}
