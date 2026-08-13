package main

import "fmt"

/* block comment */
func main() {
    // line comment
    s := "hello\nworld"
    r := `raw "string" \ with backticks not special`
    m := `first line
second line with "quotes" and \ not special until closing backtick`
    i := 42
    f := 3.14
    x := 0xFF
    t := true
    b := make([]byte, 10)
    l := len(b)
    c := 'a'
    if i > 0 {
        fmt.Println(s, r, m, i, f, x, t, c)
    }
}
