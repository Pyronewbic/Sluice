package main

import (
	"fmt"
	"net/http"

	"rsc.io/quote"
)

func main() {
	_ = quote.Hello()
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok from go") })
	http.ListenAndServe("0.0.0.0:8080", nil)
}
