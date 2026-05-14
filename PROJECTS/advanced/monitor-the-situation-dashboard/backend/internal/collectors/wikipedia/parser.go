// ©AngelaMos | 2026
// parser.go

package wikipedia

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/PuerkitoBio/goquery"
)

type Response struct {
	RevID int64
	HTML  string
}

type ITNEntry struct {
	Text        string
	ArticleSlug string
}

type rawAPI struct {
	Parse struct {
		Title string `json:"title"`
		RevID int64  `json:"revid"`
		Text  struct {
			Star string `json:"*"`
		} `json:"text"`
	} `json:"parse"`
}

func DecodeResponse(body []byte) (Response, error) {
	var r rawAPI
	if err := json.Unmarshal(body, &r); err != nil {
		return Response{}, fmt.Errorf("decode wikipedia response: %w", err)
	}
	return Response{RevID: r.Parse.RevID, HTML: r.Parse.Text.Star}, nil
}

const minEntryLen = 50

func ParseEntries(html string) []ITNEntry {
	if strings.TrimSpace(html) == "" {
		return nil
	}
	doc, err := goquery.NewDocumentFromReader(strings.NewReader(html))
	if err != nil {
		return nil
	}
	var out []ITNEntry
	doc.Find("ul li").Each(func(_ int, s *goquery.Selection) {
		text := strings.TrimSpace(s.Text())
		if text == "" || len(text) < minEntryLen ||
			!strings.Contains(text, " ") {
			return
		}
		href, ok := s.Find("a").First().Attr("href")
		if !ok {
			return
		}
		slug := slugFromHref(href)
		if slug == "" {
			return
		}
		out = append(out, ITNEntry{Text: text, ArticleSlug: slug})
	})
	return out
}

func slugFromHref(href string) string {
	const prefix = "/wiki/"
	if !strings.HasPrefix(href, prefix) {
		return ""
	}
	slug := strings.TrimPrefix(href, prefix)
	if hash := strings.Index(slug, "#"); hash >= 0 {
		slug = slug[:hash]
	}
	return slug
}
