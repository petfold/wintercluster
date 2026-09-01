// agekeygen prints an age X25519 keypair: recipient on line 1, identity on
// line 2. The harness needs one to give the BSL bucket a recovery recipient,
// and no age CLI is assumed to be installed.
package main

import (
	"fmt"

	"filippo.io/age"
)

func main() {
	id, err := age.GenerateX25519Identity()
	if err != nil {
		panic(err)
	}
	fmt.Println(id.Recipient().String())
	fmt.Println(id.String())
}
