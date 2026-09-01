// chainwalk reads a bucket's commit document straight off a Bee node, given
// only a 32-byte commit root.
//
// This is the tier-C recovery position (DESIGN §7.4) reduced to its smallest
// form: no gateway, no metadata index, no credentials — a root and a node. It
// uses only Bee's public mantaray package over the plain /bytes API, which is
// the same HTTP-only boundary wintercluster itself must respect (§5.1), so it
// doubles as a working sketch of internal/bee.
//
//	chainwalk <bee-api> <64-hex-root>
package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/ethersphere/bee/v2/pkg/manifest/mantaray"
)

// commitPath is s3warm's reserved fork holding the commit document.
const commitPath = ".s3warm/commit"

type loader struct {
	base string
	hc   *http.Client
}

func (l loader) Load(ctx context.Context, ref []byte) ([]byte, error) {
	url := l.base + "/bytes/" + hex.EncodeToString(ref)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := l.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("bee returned %d for %x", resp.StatusCode, ref)
	}
	return io.ReadAll(resp.Body)
}

// Save is never called: walking a chain is strictly a read.
func (l loader) Save(context.Context, []byte) ([]byte, error) {
	return nil, fmt.Errorf("chainwalk is read-only")
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: chainwalk <bee-api> <64-hex-root>")
		os.Exit(2)
	}
	base, rootHex := os.Args[1], os.Args[2]
	root, err := hex.DecodeString(rootHex)
	if err != nil || len(root) != 32 {
		fmt.Fprintf(os.Stderr, "root must be 64 hex characters (32 bytes): %v\n", err)
		os.Exit(2)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	ls := loader{base: base, hc: &http.Client{Timeout: 2 * time.Minute}}

	entry, err := mantaray.NewNodeRef(root).Lookup(ctx, []byte(commitPath), ls)
	if err != nil {
		fmt.Fprintf(os.Stderr, "looking up %s under %s: %v\n", commitPath, rootHex, err)
		os.Exit(1)
	}
	doc, err := ls.Load(ctx, entry)
	if err != nil {
		fmt.Fprintf(os.Stderr, "loading commit document: %v\n", err)
		os.Exit(1)
	}
	var pretty bytes.Buffer
	if json.Indent(&pretty, doc, "", "  ") != nil {
		pretty.Write(doc)
	}
	fmt.Println(pretty.String())
}
